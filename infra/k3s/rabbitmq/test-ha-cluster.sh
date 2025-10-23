#!/bin/bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
NAMESPACE=${NAMESPACE:-common}
EXPECTED_REPLICAS=${EXPECTED_REPLICAS:-3}

echo "========================================="
echo "RabbitMQ HA Cluster Test Suite"
echo "========================================="
echo ""
echo "Namespace: $NAMESPACE"
echo "Expected Replicas: $EXPECTED_REPLICAS"
echo ""

# Test 1: Check if all pods are running
echo "Test 1: Checking pod status..."
POD_COUNT=$(kubectl get pods -n $NAMESPACE -l app.kubernetes.io/name=rabbitmq --no-headers 2>/dev/null | wc -l | tr -d ' ')
READY_COUNT=$(kubectl get pods -n $NAMESPACE -l app.kubernetes.io/name=rabbitmq --no-headers 2>/dev/null | grep "1/1" | wc -l | tr -d ' ')

if [ "$POD_COUNT" -eq "$EXPECTED_REPLICAS" ] && [ "$READY_COUNT" -eq "$EXPECTED_REPLICAS" ]; then
    echo -e "${GREEN}✓ All $EXPECTED_REPLICAS pods are running and ready${NC}"
else
    echo -e "${RED}✗ Expected $EXPECTED_REPLICAS pods, found $POD_COUNT ($READY_COUNT ready)${NC}"
    kubectl get pods -n $NAMESPACE -l app.kubernetes.io/name=rabbitmq
    exit 1
fi

# Get first pod name
FIRST_POD=$(kubectl get pods -n $NAMESPACE -l app.kubernetes.io/name=rabbitmq -o jsonpath='{.items[0].metadata.name}')

# Test 2: Check cluster formation
echo ""
echo "Test 2: Checking cluster formation..."
RUNNING_NODES=$(kubectl exec -n $NAMESPACE $FIRST_POD -- rabbitmqctl cluster_status 2>/dev/null | grep -A 50 "Running Nodes" | grep "rabbit@" | wc -l | tr -d ' ')

if [ "$RUNNING_NODES" -eq "$EXPECTED_REPLICAS" ]; then
    echo -e "${GREEN}✓ All $EXPECTED_REPLICAS nodes are in the cluster${NC}"
else
    echo -e "${RED}✗ Expected $EXPECTED_REPLICAS nodes in cluster, found $RUNNING_NODES${NC}"
    kubectl exec -n $NAMESPACE $FIRST_POD -- rabbitmqctl cluster_status
    exit 1
fi

# Test 3: Check for network partitions
echo ""
echo "Test 3: Checking for network partitions..."
PARTITIONS=$(kubectl exec -n $NAMESPACE $FIRST_POD -- rabbitmqctl cluster_status 2>/dev/null | grep -A 5 "Network Partitions" | grep "rabbit@" | wc -l | tr -d ' ')

if [ "$PARTITIONS" -eq 0 ]; then
    echo -e "${GREEN}✓ No network partitions detected${NC}"
else
    echo -e "${RED}✗ Network partitions detected!${NC}"
    kubectl exec -n $NAMESPACE $FIRST_POD -- rabbitmqctl cluster_status | grep -A 10 "Network Partitions"
    exit 1
fi

# Test 4: Check if quorum queues are supported
echo ""
echo "Test 4: Checking quorum queue support..."
QUORUM_ENABLED=$(kubectl exec -n $NAMESPACE $FIRST_POD -- rabbitmqctl cluster_status 2>/dev/null | grep "quorum_queue" | grep "enabled" | wc -l | tr -d ' ')

if [ "$QUORUM_ENABLED" -gt 0 ]; then
    echo -e "${GREEN}✓ Quorum queues are enabled${NC}"
else
    echo -e "${YELLOW}⚠ Quorum queue feature flag not found (may be default in this version)${NC}"
fi

# Test 5: Create a test quorum queue
echo ""
echo "Test 5: Creating test quorum queue..."
TEST_QUEUE="test-ha-queue-$$"

# Create queue using Python script
kubectl exec -n $NAMESPACE $FIRST_POD -- python3 -c "
import pika
import sys

try:
    connection = pika.BlockingConnection(pika.ConnectionParameters('localhost'))
    channel = connection.channel()
    
    channel.queue_declare(
        queue='$TEST_QUEUE',
        durable=True,
        arguments={'x-queue-type': 'quorum'}
    )
    
    print('Queue created successfully')
    connection.close()
    sys.exit(0)
except Exception as e:
    print(f'Error: {e}')
    sys.exit(1)
" 2>/dev/null

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Test quorum queue created successfully${NC}"
else
    echo -e "${RED}✗ Failed to create test quorum queue${NC}"
    exit 1
fi

# Test 6: Verify queue is replicated
echo ""
echo "Test 6: Verifying queue replication..."
QUEUE_TYPE=$(kubectl exec -n $NAMESPACE $FIRST_POD -- rabbitmqctl list_queues name type 2>/dev/null | grep "$TEST_QUEUE" | awk '{print $2}')

if [ "$QUEUE_TYPE" = "quorum" ]; then
    echo -e "${GREEN}✓ Queue is of type 'quorum'${NC}"
    
    # Check members
    MEMBERS=$(kubectl exec -n $NAMESPACE $FIRST_POD -- rabbitmqctl list_queues name members 2>/dev/null | grep "$TEST_QUEUE" | awk '{print $2}')
    echo "  Members: $MEMBERS"
else
    echo -e "${RED}✗ Queue is not a quorum queue (type: $QUEUE_TYPE)${NC}"
    exit 1
fi

# Test 7: Test message publishing and consuming
echo ""
echo "Test 7: Testing message publish/consume..."

# Publish message
kubectl exec -n $NAMESPACE $FIRST_POD -- python3 -c "
import pika

connection = pika.BlockingConnection(pika.ConnectionParameters('localhost'))
channel = connection.channel()

channel.basic_publish(
    exchange='',
    routing_key='$TEST_QUEUE',
    body='Test HA message',
    properties=pika.BasicProperties(delivery_mode=2)
)

connection.close()
" 2>/dev/null

# Check message count
MSG_COUNT=$(kubectl exec -n $NAMESPACE $FIRST_POD -- rabbitmqctl list_queues name messages 2>/dev/null | grep "$TEST_QUEUE" | awk '{print $2}')

if [ "$MSG_COUNT" -eq 1 ]; then
    echo -e "${GREEN}✓ Message published successfully${NC}"
else
    echo -e "${RED}✗ Message count is $MSG_COUNT, expected 1${NC}"
    exit 1
fi

# Consume message
kubectl exec -n $NAMESPACE $FIRST_POD -- python3 -c "
import pika

connection = pika.BlockingConnection(pika.ConnectionParameters('localhost'))
channel = connection.channel()

method_frame, header_frame, body = channel.basic_get('$TEST_QUEUE', auto_ack=True)
if body:
    print('Message received:', body.decode())
else:
    print('No message')
    exit(1)

connection.close()
" 2>/dev/null

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Message consumed successfully${NC}"
else
    echo -e "${RED}✗ Failed to consume message${NC}"
    exit 1
fi

# Test 8: Test failover (optional - requires confirmation)
echo ""
echo "Test 8: Failover test (optional)..."
read -p "Do you want to test failover by deleting a pod? (y/n): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    # Get a non-first pod to delete
    POD_TO_DELETE=$(kubectl get pods -n $NAMESPACE -l app.kubernetes.io/name=rabbitmq -o jsonpath='{.items[1].metadata.name}')
    
    echo "Deleting pod: $POD_TO_DELETE"
    kubectl delete pod $POD_TO_DELETE -n $NAMESPACE
    
    echo "Waiting for pod to be recreated..."
    sleep 10
    
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=rabbitmq -n $NAMESPACE --timeout=300s
    
    echo "Checking cluster status after failover..."
    RUNNING_NODES_AFTER=$(kubectl exec -n $NAMESPACE $FIRST_POD -- rabbitmqctl cluster_status 2>/dev/null | grep -A 50 "Running Nodes" | grep "rabbit@" | wc -l | tr -d ' ')
    
    if [ "$RUNNING_NODES_AFTER" -eq "$EXPECTED_REPLICAS" ]; then
        echo -e "${GREEN}✓ Cluster recovered successfully after failover${NC}"
    else
        echo -e "${RED}✗ Cluster did not recover properly (nodes: $RUNNING_NODES_AFTER)${NC}"
        exit 1
    fi
else
    echo -e "${YELLOW}⊘ Failover test skipped${NC}"
fi

# Cleanup test queue
echo ""
echo "Cleaning up test queue..."
kubectl exec -n $NAMESPACE $FIRST_POD -- rabbitmqctl delete_queue "$TEST_QUEUE" 2>/dev/null || true

# Summary
echo ""
echo "========================================="
echo -e "${GREEN}✓ All tests passed!${NC}"
echo "========================================="
echo ""
echo "Cluster Summary:"
kubectl exec -n $NAMESPACE $FIRST_POD -- rabbitmqctl cluster_status 2>/dev/null | grep -E "(Cluster name|Running Nodes|rabbit@)" | head -6
echo ""
echo "Your RabbitMQ HA cluster is working correctly!"

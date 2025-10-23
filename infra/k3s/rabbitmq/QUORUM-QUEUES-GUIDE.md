# RabbitMQ Quorum Queues Guide

## What are Quorum Queues?

Quorum queues are a modern, replicated queue type in RabbitMQ that provides:
- **High Availability**: Data is replicated across multiple nodes
- **Data Safety**: Uses Raft consensus algorithm for consistency
- **Automatic Failover**: Leader election happens automatically
- **Poison Message Handling**: Built-in dead letter queue support

## Why Quorum Queues for HA?

| Feature | Classic Queues | Quorum Queues |
|---------|---------------|---------------|
| Replication | Manual (mirroring) | Automatic |
| Data Safety | Best effort | Guaranteed |
| Failover | Manual intervention may be needed | Automatic |
| Performance | Higher throughput | Optimized for safety |
| RabbitMQ 4.x | Mirroring deprecated | Recommended |

## Creating Quorum Queues

### Default Behavior (with our setup)
Our installation sets `default_queue_type = quorum`, so **all new queues are quorum queues by default**.

### Python (pika)

```python
import pika

connection = pika.BlockingConnection(
    pika.ConnectionParameters('rabbitmq.common.svc.cluster.local')
)
channel = connection.channel()

# Explicit quorum queue (recommended for clarity)
channel.queue_declare(
    queue='my-ha-queue',
    durable=True,
    arguments={
        'x-queue-type': 'quorum',
        'x-max-length': 100000,  # Optional: limit queue size
        'x-overflow': 'reject-publish'  # Optional: reject when full
    }
)

# With dead letter exchange for poison messages
channel.queue_declare(
    queue='my-ha-queue-with-dlx',
    durable=True,
    arguments={
        'x-queue-type': 'quorum',
        'x-dead-letter-exchange': 'dlx-exchange',
        'x-dead-letter-routing-key': 'failed-messages'
    }
)
```

### Node.js (amqplib)

```javascript
const amqp = require('amqplib');

async function createQuorumQueue() {
    const connection = await amqp.connect('amqp://rabbitmq.common.svc.cluster.local');
    const channel = await connection.createChannel();
    
    // Explicit quorum queue
    await channel.assertQueue('my-ha-queue', {
        durable: true,
        arguments: {
            'x-queue-type': 'quorum',
            'x-max-length': 100000,
            'x-overflow': 'reject-publish'
        }
    });
    
    // With dead letter exchange
    await channel.assertQueue('my-ha-queue-with-dlx', {
        durable: true,
        arguments: {
            'x-queue-type': 'quorum',
            'x-dead-letter-exchange': 'dlx-exchange',
            'x-dead-letter-routing-key': 'failed-messages'
        }
    });
}
```

### Go (amqp091-go)

```go
package main

import (
    "log"
    amqp "github.com/rabbitmq/amqp091-go"
)

func main() {
    conn, err := amqp.Dial("amqp://rabbitmq.common.svc.cluster.local")
    if err != nil {
        log.Fatal(err)
    }
    defer conn.Close()
    
    ch, err := conn.Channel()
    if err != nil {
        log.Fatal(err)
    }
    defer ch.Close()
    
    // Explicit quorum queue
    _, err = ch.QueueDeclare(
        "my-ha-queue",  // name
        true,           // durable
        false,          // autoDelete
        false,          // exclusive
        false,          // noWait
        amqp.Table{
            "x-queue-type": "quorum",
            "x-max-length": 100000,
            "x-overflow": "reject-publish",
        },
    )
    if err != nil {
        log.Fatal(err)
    }
    
    // With dead letter exchange
    _, err = ch.QueueDeclare(
        "my-ha-queue-with-dlx",
        true,
        false,
        false,
        false,
        amqp.Table{
            "x-queue-type": "quorum",
            "x-dead-letter-exchange": "dlx-exchange",
            "x-dead-letter-routing-key": "failed-messages",
        },
    )
}
```

### Java (Spring AMQP)

```java
import org.springframework.amqp.core.Queue;
import org.springframework.amqp.core.QueueBuilder;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration
public class RabbitMQConfig {
    
    @Bean
    public Queue quorumQueue() {
        return QueueBuilder.durable("my-ha-queue")
                .quorum()
                .maxLength(100000)
                .overflow(QueueBuilder.Overflow.rejectPublish)
                .build();
    }
    
    @Bean
    public Queue quorumQueueWithDLX() {
        return QueueBuilder.durable("my-ha-queue-with-dlx")
                .quorum()
                .deadLetterExchange("dlx-exchange")
                .deadLetterRoutingKey("failed-messages")
                .build();
    }
}
```

## Migrating Existing Classic Queues

### Strategy 1: Blue-Green Migration (Recommended)

1. **Create new quorum queues** with different names
2. **Update consumers** to listen to new queues
3. **Update producers** to publish to new queues
4. **Drain old queues** (wait for messages to be processed)
5. **Delete old classic queues**

```bash
# Check existing queues
kubectl exec -n common rabbitmq-server-0 -- rabbitmqctl list_queues name type messages

# After migration, verify
kubectl exec -n common rabbitmq-server-0 -- rabbitmqctl list_queues name type messages consumers
```

### Strategy 2: Shovel Migration (Zero Downtime)

Use RabbitMQ Shovel to move messages from classic to quorum queues:

```bash
# Create shovel to move messages
kubectl exec -n common rabbitmq-server-0 -- rabbitmqctl set_parameter shovel my-shovel \
'{"src-uri":"amqp://","src-queue":"old-classic-queue","dest-uri":"amqp://","dest-queue":"new-quorum-queue"}'

# Monitor shovel
kubectl exec -n common rabbitmq-server-0 -- rabbitmqctl shovel_status

# Delete shovel when done
kubectl exec -n common rabbitmq-server-0 -- rabbitmqctl clear_parameter shovel my-shovel
```

## Quorum Queue Best Practices

### 1. Queue Configuration

```python
# Recommended settings
channel.queue_declare(
    queue='production-queue',
    durable=True,
    arguments={
        'x-queue-type': 'quorum',
        
        # Limit queue size to prevent memory issues
        'x-max-length': 100000,
        'x-overflow': 'reject-publish',  # or 'drop-head'
        
        # Dead letter exchange for failed messages
        'x-dead-letter-exchange': 'dlx',
        'x-dead-letter-routing-key': 'failed',
        
        # Delivery limit (RabbitMQ 3.10+)
        'x-delivery-limit': 3,  # Move to DLX after 3 failed deliveries
    }
)
```

### 2. Consumer Configuration

```python
# Use manual acknowledgment
channel.basic_qos(prefetch_count=10)  # Limit unacked messages

def callback(ch, method, properties, body):
    try:
        # Process message
        process_message(body)
        ch.basic_ack(delivery_tag=method.delivery_tag)
    except Exception as e:
        # Reject and requeue (or send to DLX if delivery limit reached)
        ch.basic_nack(delivery_tag=method.delivery_tag, requeue=True)

channel.basic_consume(
    queue='production-queue',
    on_message_callback=callback,
    auto_ack=False  # Important: manual ack
)
```

### 3. Publisher Configuration

```python
# Use publisher confirms for reliability
channel.confirm_delivery()

try:
    channel.basic_publish(
        exchange='',
        routing_key='production-queue',
        body='message',
        properties=pika.BasicProperties(
            delivery_mode=2,  # Persistent message
        ),
        mandatory=True  # Return message if unroutable
    )
    print("Message confirmed")
except pika.exceptions.UnroutableError:
    print("Message was returned (queue doesn't exist?)")
except pika.exceptions.NackError:
    print("Message was nacked by broker")
```

## Monitoring Quorum Queues

### Check Queue Status

```bash
# List all queues with type
kubectl exec -n common rabbitmq-server-0 -- rabbitmqctl list_queues name type messages consumers

# Detailed queue info
kubectl exec -n common rabbitmq-server-0 -- rabbitmqctl list_queues name type messages consumers memory leader members
```

### Check Cluster Status

```bash
# Overall cluster health
kubectl exec -n common rabbitmq-server-0 -- rabbitmqctl cluster_status

# Check quorum queue leaders distribution
kubectl exec -n common rabbitmq-server-0 -- rabbitmqctl list_queues name leader members | grep quorum
```

### Prometheus Metrics

Quorum queues expose metrics on port 15692:

```bash
# Port forward to access metrics
kubectl port-forward -n common svc/rabbitmq 15692:15692

# Access metrics
curl http://localhost:15692/metrics | grep rabbitmq_queue
```

## Troubleshooting

### Queue Not Replicating

```bash
# Check if queue is actually quorum type
kubectl exec -n common rabbitmq-server-0 -- rabbitmqctl list_queues name type

# Check cluster has enough nodes (minimum 3 for quorum)
kubectl get pods -n common -l app.kubernetes.io/name=rabbitmq
```

### High Memory Usage

```bash
# Check queue memory
kubectl exec -n common rabbitmq-server-0 -- rabbitmqctl list_queues name memory messages

# Set max-length on queues
kubectl exec -n common rabbitmq-server-0 -- rabbitmqctl set_policy max-length-policy ".*" \
  '{"max-length":50000,"overflow":"reject-publish"}' --apply-to queues
```

### Leader Election Issues

```bash
# Check which node is leader
kubectl exec -n common rabbitmq-server-0 -- rabbitmqctl list_queues name leader

# Force leader election (if needed)
kubectl delete pod rabbitmq-server-0 -n common
```

## Performance Considerations

### Throughput
- Quorum queues: ~20-50k msg/sec per queue
- Classic queues: ~50-100k msg/sec per queue
- **Trade-off**: Quorum queues prioritize safety over raw speed

### Latency
- Quorum queues: Slightly higher latency due to Raft consensus
- Typical: 1-5ms additional latency
- **Acceptable** for most production workloads

### Scaling
- **Horizontal**: Add more queues (sharding)
- **Vertical**: Increase node resources
- **Best practice**: Multiple queues with consistent hashing

## References

- [RabbitMQ Quorum Queues Documentation](https://www.rabbitmq.com/quorum-queues.html)
- [Quorum Queue Performance](https://www.rabbitmq.com/quorum-queues.html#performance)
- [Migration Guide](https://www.rabbitmq.com/quorum-queues.html#migration)

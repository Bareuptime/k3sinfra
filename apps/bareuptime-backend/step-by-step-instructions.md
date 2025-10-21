# Step-by-Step Deployment Guide: BareUptime Backend

Welcome to your detailed deployment guide! This document will walk you through every step of deploying the `bareuptime-backend` application onto your Kubernetes cluster. The goal is to make every part of the process clear, even the complex parts.

## Philosophy: What is GitOps?

Before we dive in, let's quickly touch on the "why". Your setup uses a modern approach called **GitOps**.

-   **Git as the Single Source of Truth:** The Git repository (`new-infra`) is the "master copy" of your desired infrastructure. Any change to your application or its configuration must be made in Git.
-   **Automation with ArgoCD:** A tool called **ArgoCD** acts as a robot that constantly compares the state of your Kubernetes cluster with the state defined in your Git repository.
-   **Automatic Reconciliation:** If ArgoCD detects any difference (e.g., you update a file in Git), it automatically "fixes" the cluster to match the repository.

This means you don't manually change things in the cluster. You change them in Git, and the system updates itself. It's reliable, auditable, and powerful.

---

## Part 1: Prerequisites - Setting the Stage

This guide assumes you have a working K3s Kubernetes cluster with a few key components already installed and configured. Your `new-infra` repository is designed to set these up. Here’s a quick check of what should be ready:

| Tool / Component | What it is | Why it's needed |
| :--- | :--- | :--- |
| `kubectl` | The command-line tool for interacting with your Kubernetes cluster. | It's our primary tool for sending commands to the cluster. |
| `helm` | A package manager for Kubernetes. | Used to install complex applications like the External Secrets Operator. |
| **Traefik** | The Ingress Controller. | It's the "front door" for all traffic from the internet to your applications, handling routing and SSL. |
| **cert-manager** | An automatic certificate manager. | It works with Traefik to provide free, auto-renewing HTTPS certificates from Let's Encrypt. |
| **Vault** | A secure secrets manager. | It stores all your sensitive data (passwords, API keys) encrypted in one central place. |
| **External Secrets Operator (ESO)** | The bridge between Vault and Kubernetes. | It securely fetches secrets from Vault and makes them available to your application inside the cluster. |

---

## Part 2: Configuring Access to Private Resources

This is a critical step. Your application code is in a **private GitHub repository**, and your application's container image is likely in a **private Docker registry** (like GitHub Container Registry - GHCR). We need to give our cluster the credentials to access them.

### Section 2.1: Granting ArgoCD Access to Your Private Git Repository

**The Goal:** To allow ArgoCD (which runs in its own `argocd` namespace) to clone the code from `https://github.com/bareuptime/backend.git`.

**The Method:** We will create a Kubernetes `Secret` in the `argocd` namespace containing a GitHub credential. ArgoCD is smart enough to automatically find and use this secret when it sees a repository that needs it.

**Step-by-Step Instructions:**

1.  **Create a GitHub Credential:** You have two main options:
    *   **Deploy Key (Recommended for a single repository):**
        1.  Go to your private `bareuptime/backend` repository on GitHub.
        2.  Navigate to `Settings` > `Deploy Keys` > `Add deploy key`.
        3.  Create a new SSH key pair on your local machine (`ssh-keygen -t ed25519 -C "argocd-deploy-key"`).
        4.  Copy the **public key** (`.pub` file) into the deploy key content on GitHub. Give it a title like "ArgoCD". **Do not** check "Allow write access".
        5.  You will use the **private key** in the next step.
    *   **Personal Access Token (PAT):**
        1.  Go to your GitHub `Developer settings` > `Personal access tokens`.
        2.  Generate a new token with the `repo` scope.
        3.  **Copy this token immediately.** This is the only time you will see it.

2.  **Create the Kubernetes Secret for ArgoCD:**

You will now run a `kubectl` command to create the secret that ArgoCD will use.

    *   **If you are using a Deploy Key (SSH):**

        ```bash
        # This command creates a secret named 'argocd-repo-creds' in the 'argocd' namespace.
        # ArgoCD will automatically use this secret for any repository matching the host.
        kubectl create secret generic argocd-repo-creds \
          --namespace=argocd \
          --from-literal=type=git \
          --from-literal=url=https://github.com/bareuptime/backend \
          --from-file=sshPrivateKey=/path/to/your/private_ssh_key
        ```

    *   **If you are using a Personal Access Token (HTTPS):**

        ```bash
        # This command creates a secret named 'argocd-repo-creds' in the 'argocd' namespace.
        # The username can be your GitHub username. The password is the Personal Access Token.
        kubectl create secret generic argocd-repo-creds \
          --namespace=argocd \
          --from-literal=type=git \
          --from-literal=url=https://github.com/bareuptime/backend \
          --from-literal=username=<YOUR_GITHUB_USERNAME> \
          --from-literal=password=<YOUR_PERSONAL_ACCESS_TOKEN>
        ```

With this secret in place, ArgoCD now has the keys to the castle and can access your private repository.

### Section 2.2: Granting Kubernetes Access to Your Private Docker Image Registry (GHCR)

**The Goal:** To allow Kubernetes to pull the `bareuptime/backend` Docker image from a private registry like GitHub Container Registry (GHCR).

**The Method:** This process is cleverly automated by your existing setup.
1. We store GitHub credentials in **Vault**.
2. The **External Secrets Operator (ESO)** syncs them into a Kubernetes `Secret`.
3. The application's `Deployment` manifest tells the pods to use this `Secret` to pull the image.

**Step-by-Step Instructions:**

1.  **Ensure GitHub Credentials are in Vault:**
    Your `README.md` already outlines this. You need a GitHub Personal Access Token (PAT) with the `read:packages` scope. Store it in Vault like this:

    ```bash
    # Login to vault first
    vault kv put secret/shared/ghcr \
      username="<your-github-username>" \
      password="<your-github-pat-with-read:packages-scope>"
    ```

2.  **Understand the Magic in `secrets.yaml`:**
    Look inside the `apps/bareuptime-backend/secrets.yaml` file. You will see a resource of kind `ExternalSecret` named `ghcr-credentials`.
    -   It points to the `secret/shared/ghcr` path in Vault.
    -   It tells ESO to create a Kubernetes `Secret` named `ghcr-credentials` of type `kubernetes.io/dockerconfigjson`. This is the specific type of secret Kubernetes needs for pulling images.

3.  **Check the `manifests.yaml`:**
    In the `apps/bareuptime-backend/manifests.yaml` file, look for the `Deployment` resource. Inside its `spec.template.spec`, you will find a section:
    ```yaml
    imagePullSecrets:
    - name: ghcr-credentials
    ```
    This line explicitly tells any pod created by this Deployment to use the `ghcr-credentials` secret when pulling its Docker image.

---

## Part 3: The Deployment Manifests - Your Application's Blueprint

Your application is defined by a set of YAML files in the `apps/bareuptime-backend` directory. Let's break them down.

| File | Purpose |
| :--- | :--- |
| `argocd-application.yaml` | **The Conductor.** This file tells ArgoCD about your application. |
| `kustomization.yaml` | **The Assembler.** This file tells the `kustomize` tool to bundle all the other `.yaml` files into one giant list of resources for deployment. |
| `manifests.yaml` | **The Core Infrastructure.** Defines the fundamental Kubernetes objects for your app. |
| `secrets.yaml` | **The Keymaster.** Defines how to get secrets from Vault. |
| `ingress.yaml` | **The Front Door.** Defines how your application is exposed to the internet. |

### `argocd-application.yaml` - The Conductor

This is the file we are applying manually. It tells ArgoCD: "Hey, there is an application you need to manage!"

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: bareuptime-backend # The name for this application in ArgoCD
  namespace: argocd       # ArgoCD applications must be in the argocd namespace
spec:
  project: default

  source:
    # This is the repository ArgoCD will watch for changes.
    # I have updated this to your private backend repository.
    repoURL: https://github.com/bareuptime/backend.git
    targetRevision: main # The branch to track
    # The folder within the repo containing the manifests.
    # I have made an educated guess that it's 'k8s'.
    # If your manifests are in a different folder, you must change this path!
    path: k8s

  destination:
    server: https://kubernetes.default.svc # This means deploy to the same cluster ArgoCD is in
    namespace: bareuptime-backend          # The namespace where the app will be deployed

  syncPolicy:
    automated: # Tells ArgoCD to automatically sync changes from Git
      prune: true    # If you delete a file in Git, ArgoCD deletes the corresponding resource
      selfHeal: true # If someone manually changes the cluster, ArgoCD changes it back
```

---

## Part 4: The Deployment - Bringing Your Application to Life

This is the simplest step in the entire process.

**The Command:**

```bash
# Navigate to the root of your 'new-infra' repository
# Then run this single command:
kubectl apply -f apps/bareuptime-backend/argocd-application.yaml
```

**What Happens Next (The Chain Reaction):**

1.  You tell Kubernetes to create the `Application` resource defined in the file.
2.  ArgoCD, which is always watching for these resources, sees the new `bareuptime-backend` application.
3.  ArgoCD reads the `source` information. It uses the `argocd-repo-creds` secret you created to access the private `bareuptime/backend` Git repository.
4.  It looks in the `k8s` folder of that repository and reads all the Kubernetes manifests defined there (thanks to `kustomization.yaml`).
5.  ArgoCD then applies all those manifests to the cluster, which triggers a cascade of events:
    *   The `bareuptime-backend` namespace is created.
    *   The `ExternalSecret` resources are created.
    *   The External Secrets Operator (ESO) sees these, connects to Vault, fetches the secrets, and creates the final Kubernetes `Secret` objects (like `database-credentials` and `ghcr-credentials`).
    *   The `Deployment` is created. It tries to create pods.
    *   The pods use the `ghcr-credentials` secret to successfully pull the private Docker image.
    *   The pods start, mounting all the other secrets as environment variables or files.
    *   The `Service` is created to give the pods a stable internal network address.
    *   The `IngressRoute` and `Certificate` are created. `cert-manager` sees the `Certificate` and fetches a new SSL certificate from Let's Encrypt. Traefik sees the `IngressRoute` and configures itself to route traffic from `api1.bareuptime.co` to your application.
6.  **Done.** Your application is now running, secure, and accessible.

---

## Part 5: Verification and Troubleshooting - Checking the Pulse

Your application is deploying, but how do you know it's working? Here are the commands to check the health of every component.

1.  **Check ArgoCD's Status:**
    ```bash
    # See if ArgoCD thinks the application is healthy and synced
    kubectl get application bareuptime-backend -n argocd -w

    # The '-w' flag means "watch". It will update automatically.
    # Look for HEALTHY and SYNCED status.
    ```
    If it shows an error here, it often means ArgoCD couldn't access your Git repository. Double-check the `argocd-repo-creds` secret.

2.  **Check Your Application's Namespace:**
    ```bash
    # This command shows you all the major resources in your app's namespace
    kubectl get pods,svc,pvc,ingressroute,externalsecret -n bareuptime-backend
    ```
    *   `pods`: Should be `Running`. If they are `ImagePullBackOff` or `CrashLoopBackOff`, there's a problem.
    *   `svc` (Service): Should exist.
    *   `pvc` (PersistentVolumeClaim): Should be `Bound`.
    *   `ingressroute`: Should exist.
    *   `externalsecret`: Should show `SYNCED`.

3.  **Diagnosing Pod Issues:**
    *   **Image Pull Errors (`ImagePullBackOff`):**
        ```bash
        # Describe the pod to see the error message
        kubectl describe pod <pod-name> -n bareuptime-backend
        ```
        This usually means the `ghcr-credentials` secret is wrong or wasn't created. Check the logs of the External Secrets Operator: `kubectl logs -n external-secrets-system -l app.kubernetes.io/name=external-secrets`.

    *   **Application Crashing (`CrashLoopBackOff`):**
        ```bash
        # Check the logs of the crashing pod
        kubectl logs <pod-name> -n bareuptime-backend
        ```
        This is likely an application bug or a missing/incorrect configuration (e.g., a bad database URL passed from a secret).

4.  **Check the Certificates and Ingress:**
    ```bash
    # Check if the certificate was issued successfully
    kubectl get certificate -n bareuptime-backend

    # Check the Traefik logs to see if it configured the route
    kubectl logs -n kube-system -l app.kubernetes.io/name=traefik
    ```

5.  **Test the Endpoint:**
    ```bash
    # Finally, test if you can reach your application from the internet
    curl -k https://api1.bareuptime.co/health
    ```

This guide covers the entire lifecycle of your application deployment. By understanding each piece of the puzzle, you are now in full control of your infrastructure.

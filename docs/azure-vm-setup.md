# Azure VM Setup with Azure CLI

Step-by-step guide to create the VM that hosts the Snippet Searcher Docker
Swarm stack. Everything is done with the Azure CLI (`az`) and plain shell
commands, so every step can be read, copied and repeated by anyone.

The result is **one Ubuntu VM** that is a **single-node Docker Swarm
manager**, with a static public IP and ports `22`, `80` and `443` open.
Repeat the guide once per environment (`dev` and `prod`).

## 0. Decisions

| Item | Value                                   | Notes                                                                                                                               |
|---|-----------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------|
| OS | Ubuntu Server 22.04 LTS                 |                                                                                                                                     |
| Size | `Standard_B2als_v2` (2 vCPU, 4 GiB RAM) | Runs 7 services: two Spring applications, two PostgreSQL databases, Azurite, PrintScript UI and Nginx. |
| Disk | 30 GB Standard SSD                      | Volumes (Postgres, Azurite) live here.                                                                                              |
| Swarm | Single manager                          | No workers needed.                                                                                                                  |
| Open ports | 22, 80, 443                             | Never expose Docker's 2375/2376.                                                                                                    |
| Auth | SSH key only                            | No passwords.                                                                                                                       |

> **Azure for Students:** some sizes/regions are blocked for your
> subscription. If `az vm create` fails with `SkuNotAvailable` or a quota
> error, list what you can use (section 2) and change `VM_SIZE` / `LOCATION`.

## 1. Prerequisites (on your own machine)

### 1.1 Install Azure CLI

- Linux: https://learn.microsoft.com/cli/azure/install-azure-cli-linux
- Windows: https://learn.microsoft.com/cli/azure/install-azure-cli-windows

### 1.2 Log in and select your subscription

```bash
az login

az account list --output table

az account set --subscription "<SUBSCRIPTION_NAME_OR_ID>"
```

### 1.3 Prepare an SSH key pair

Azure VM access uses SSH public-key authentication.

First, check if you already have an SSH key pair:

```bash
ls -la ~/.ssh/
```

Look for a matching private/public key pair, for example:

```text
id_ed25519
id_ed25519.pub
```

- If you already have a suitable key pair, you can reuse it like this: 
```bash
SSH_KEY="$HOME/.ssh/id_ed25519.pub"
```
- if you have a private key but its public key file is missing, regenerate it:
```bash
  ssh-keygen -y -f ~/.ssh/<PRIVATE_KEY_FILE> > ~/.ssh/<PRIVATE_KEY_FILE>.pub
```
Set SSH_KEY in azure-vm.env to the path of the public key.

- Otherwise, generate a dedicated key pair for this project:

```bash
ssh-keygen -t ed25519 \
  -C "snippet-searcher-azure" \
  -f ~/.ssh/snippet-searcher-azure
```

You will be asked to enter a passphrase.

- A passphrase provides additional protection if the private key is compromised.
- You can leave it empty for a simpler setup, although using a passphrase is recommended.

The command generates two files:

| File | Purpose | Handling |
|---|---|---|
| `snippet-searcher-azure` | Private key | Keep it secret. Never upload it to Azure or commit it to Git. |
| `snippet-searcher-azure.pub` | Public key | This is the file supplied to Azure when creating the VM. |

Verify that both files exist:

```bash
ls -l ~/.ssh/snippet-searcher-azure*
```

The public key will be referenced in `azure-vm.env`:

```bash
SSH_KEY="$HOME/.ssh/snippet-searcher-azure.pub"
```

**Important:** Azure receives only the public key. The private key remains on your machine and is used when connecting to the VM.

## 2. Check what you are allowed to create

```bash
az vm list-skus --location chilecentral --size Standard_B2als_v2 --output table
```

If a size shows `NotAvailableForSubscription` under *Restrictions*, pick
another size or another region (e.g. `brazilsouth`, `eastus2`, `westus3`).

## 3. Set variables

Values such as the admin username and your IP are **not** written in this
guide, and must never be committed. Keep them in a local, git-ignored file:

```bash
cp docs/azure-vm.env.example azure-vm.env
nano azure-vm.env                  # fill in your own values
set -a; source azure-vm.env; set +a
```

Rules for the values:

- `ADMIN_USER`: choose your own; do not use `azureuser`, `admin` or `root`.
- `SSH_KEY`: path to the **public** key only.
- `SSH_ALLOWED_IP`: your public IP (`curl -s ifconfig.me`); only this address
  will be able to reach SSH.
- `NAME_SUFFIX`: random suffix so resource names are not guessable.

Load the file again (`source`) whenever you open a new terminal.
`azure-vm.env` is ignored by git (see `.gitignore`); check with
`git status` that it never shows up.

## 4. Create the Azure resources

### 4.1 Resource group

A resource group is a folder that holds everything. Deleting it deletes
everything inside, which makes cleanup easy.

```bash
az group create --name $RG --location $LOCATION --tags project=snippet-searcher env=$ENV
```

### 4.2 Network (VNet and subnet)

```bash
az network vnet create \
  --resource-group $RG --name $VNET \
  --address-prefixes 10.0.0.0/16 \
  --subnet-name $SUBNET --subnet-prefixes 10.0.1.0/24
```

### 4.3 Static public IP

It must be **static**: DuckDNS and the TLS certificate point to it.

```bash
az network public-ip create \
  --resource-group $RG --name $PIP \
  --sku Standard --allocation-method Static
```

### 4.4 Firewall (network security group)

```bash
az network nsg create --resource-group $RG --name $NSG

az network nsg rule create --resource-group $RG --nsg-name $NSG \
  --name Allow-SSH --priority 100 --direction Inbound --access Allow \
  --protocol Tcp --destination-port-ranges 22 \
  --source-address-prefixes $SSH_ALLOWED_IP

az network nsg rule create --resource-group $RG --nsg-name $NSG \
  --name Allow-HTTP --priority 110 --direction Inbound --access Allow \
  --protocol Tcp --destination-port-ranges 80

az network nsg rule create --resource-group $RG --nsg-name $NSG \
  --name Allow-HTTPS --priority 120 --direction Inbound --access Allow \
  --protocol Tcp --destination-port-ranges 443
```

SSH is reachable only from `$SSH_ALLOWED_IP`, and key-only. Ports 80 and 443
are public. If your home IP changes, update the rule:
`az network nsg rule update -g $RG --nsg-name $NSG -n Allow-SSH --source-address-prefixes <NEW_IP>`.

GitHub-hosted runners have no fixed IP, so the CD workflows open port 22 to
the runner's IP only (rule `Allow-GitHub-Deploy`, priority 105) for the
duration of the deployment and delete it afterwards, even if the deploy
fails. They log in to Azure with OIDC, so no Azure password is stored in
GitHub. Use a dedicated deploy key for SSH, never your personal one.

#### 4.4.1 Let GitHub Actions manage that rule (once per environment)

The identity used by the workflow may only change security rules of this
one NSG. Do not give it Contributor.

```bash
SUB_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
NSG_ID=$(az network nsg show -g $RG -n $NSG --query id -o tsv)

# 1. App registration and service principal
APP_ID=$(az ad app create --display-name "gha-deploy-$ENV" --query appId -o tsv)
az ad sp create --id $APP_ID

# 2. Custom role limited to security rules and reading the NSG
az role definition create --role-definition '{
  "Name": "Snippet NSG rule deployer",
  "Description": "Create and delete security rules on an NSG",
  "Actions": [
    "Microsoft.Network/networkSecurityGroups/read",
    "Microsoft.Network/networkSecurityGroups/securityRules/read",
    "Microsoft.Network/networkSecurityGroups/securityRules/write",
    "Microsoft.Network/networkSecurityGroups/securityRules/delete",
    "Microsoft.Network/networkSecurityGroups/join/action"
  ],
  "AssignableScopes": ["/subscriptions/'$SUB_ID'"]
}'   # only once per subscription; skip if it already exists

# 3. Assign it on this NSG only
az role assignment create --assignee $APP_ID \
  --role "Snippet NSG rule deployer" --scope $NSG_ID

# 4. Trust the GitHub Environment (no client secret is created)
az ad app federated-credential create --id $APP_ID --parameters '{
  "name": "github-'$ENV'",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:<OWNER>/<REPO>:environment:'$ENV'",
  "audiences": ["api://AzureADTokenExchange"]
}'

echo "AZURE_CLIENT_ID=$APP_ID AZURE_TENANT_ID=$TENANT_ID AZURE_SUBSCRIPTION_ID=$SUB_ID"
```

Set these as **variables** (not secrets, they are identifiers) of the GitHub
Environment `$ENV`: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`,
`AZURE_SUBSCRIPTION_ID`, `AZURE_RESOURCE_GROUP` (`$RG`) and `AZURE_NSG_NAME`
(`$NSG`).

### 4.5 Network interface

```bash
az network nic create \
  --resource-group $RG --name $NIC \
  --vnet-name $VNET --subnet $SUBNET \
  --public-ip-address $PIP \
  --network-security-group $NSG
```

### 4.6 The virtual machine

```bash
az vm create \
  --resource-group $RG --name $VM \
  --size $VM_SIZE \
  --image Canonical:0001-com-ubuntu-server-jammy:22_04-lts:latest \
  --nics $NIC \
  --admin-username $ADMIN_USER \
  --ssh-key-values $SSH_KEY \
  --authentication-type ssh \
  --os-disk-size-gb 30 \
  --storage-sku StandardSSD_LRS \
  --tags project=snippet-searcher env=$ENV role=swarm-manager
```

### 4.7 Get the public IP

```bash
VM_IP=$(az network public-ip show -g $RG -n $PIP --query ipAddress -o tsv)
echo $VM_IP
```

Write it down. You will use it for DuckDNS and SSH.

### 4.8 Verify

```bash
ssh -i "${SSH_KEY%.pub}" "$ADMIN_USER@$VM_IP"
```

You should get an Ubuntu shell. (Answer `yes` to the host fingerprint
question the first time.) Remaining steps run **inside the VM** unless
stated otherwise.

## 5. DuckDNS

On <https://www.duckdns.org>, create (or edit) the subdomain
`<name>.duckdns.org` and set its IP to `$VM_IP`. Check from your machine:

```bash
dig +short <name>.duckdns.org     # must print the VM IP
```

## 6. Install Docker (inside the VM)

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl

sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
```

Let your user run Docker without `sudo` (needed for Docker Context over SSH):

```bash
sudo usermod -aG docker $USER
exit            # log out ...
ssh $ADMIN_USER@$VM_IP   # ... and back in
docker run --rm hello-world
```

## 7. Initialize Swarm (inside the VM)

```bash
docker swarm init --advertise-addr $(hostname -I | awk '{print $1}')
docker node ls          # one node, status Ready, role Leader
```

There is nothing else to do: no workers, no extra managers.

## 8. Prepare the host for the stack (inside the VM)

```bash
# Webroot for Let's Encrypt HTTP-01 challenges (see README, "Let's Encrypt")
sudo mkdir -p /var/www/certbot

# Certbot
sudo snap install --classic certbot

# Optional but recommended on 4 GB RAM: 2 GB swap
sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

Clone this repository on the VM (needed by `certbot-init.sh` and the
renewal hook):

```bash
git clone https://github.com/Ingsis-BRY/snippet-searcher-infra.git
cd snippet-searcher-infra
```
### 8.1 TLS certificates and private keys

The application is exposed through Nginx using HTTPS.

TLS certificates are issued and renewed by Let's Encrypt using Certbot.

The certificate files are stored on the VM:

```text
/etc/letsencrypt/
└── live/
    └── <DOMAIN>/
        ├── fullchain.pem
        └── privkey.pem
```

- `fullchain.pem`: certificate chain presented by Nginx.
- `privkey.pem`: private key used for TLS. This file must remain secret.

These files must never be committed to GitHub or copied into the application repository.

The Nginx service does not mount the private key directly from the host. Instead, the deployment process creates Docker Swarm secrets from the certificate files:

```text
Host filesystem
    |
    v
/etc/letsencrypt/live/<DOMAIN>/
    |
    v
Docker Swarm secrets
    |
    v
Nginx container
    |
    v
/run/secrets/tls_cert
/run/secrets/tls_key
```

A Certbot renewal deploy hook updates the corresponding Docker Swarm secrets
and refreshes the Nginx service whenever the certificate is renewed.

The certificate files are managed by Certbot under `/etc/letsencrypt/`.
Do not manually copy them into the application or infrastructure repositories.

### 8.2 Docker secrets

Passwords and keys are Docker secrets, not files. Create them once on the
manager (values are typed at a hidden prompt):

```bash
./scripts/create-secrets.sh
```

Non-secret settings (image names, database names, Auth0 domain) are supplied
as environment variables by the CD workflow; see the CI/CD section of the
main README.

## 9. Log in to GitHub Container Registry (inside the VM)

The Docker images are hosted on GitHub Container Registry (GHCR).

Create a GitHub Personal Access Token (classic) with the minimum required permission:

- `read:packages`

Then authenticate Docker from the VM:

```bash
echo "<TOKEN>" | docker login ghcr.io -u <GITHUB_USERNAME> --password-stdin
```

The login credentials are stored by Docker on the VM and allow it to pull private images.

`scripts/deploy.sh` uses `--with-registry-auth` to forward registry authentication to Swarm when deploying services.

## 10. Manage the VM remotely with Docker Context (on your machine)

This lets you run `docker` commands against the VM over SSH without exposing
Docker's TCP API (ports 2375/2376) to the network.

```bash
docker context create snippet-$ENV --docker "host=ssh://$ADMIN_USER@$VM_IP"
docker --context snippet-$ENV node ls      # shows the VM's Swarm node
docker context use snippet-$ENV            # make it the default (docker context use default to go back)
```

## 11. Next steps

1. Create the Docker secrets (section 8.2).
2. Issue the TLS certificate by following the Let's Encrypt instructions in
   [the main README](../README.md).
3. Authenticate Docker with GHCR (section 9).
4. Create the shared overlay networks, then deploy the stacks for the first time by hand, the shared
   one first with a self-signed certificate for the bootstrap (see TLS in the main README), and the
   non-secret variables (including the four `*_IMAGE` ones) exported in your shell:

```bash
sudo scripts/create-networks.sh
sudo -E TLS_CERT_FILE=<cert> TLS_KEY_FILE=<key> ./scripts/deploy.sh infra
for stack in service permission engine ui; do sudo -E ./scripts/deploy.sh "$stack"; done
```
Later deployments are done by GitHub Actions.

Verify that all services are running:
```bash
docker stack ls
docker service ls
```
All services should report their desired replicas (1/1, the engine 2/2).

## Security notes

- Never commit private keys, tokens or env files. Application secrets live only in Docker secrets.
- Never commit TLS private keys or copy them into application repositories.
- The GHCR token needs only `read:packages`; store it in a password manager.
- Password login is disabled; SSH is key-only and limited to one IP.
- Only trusted users should belong to the `docker` group, since Docker access
  effectively grants root-level privileges.
- Docker named volumes persist data across container recreation and VM reboots,
  but they do not protect against VM disk loss. Keep backups outside the VM.
- Optional hardening inside the VM:
  `sudo apt-get install -y fail2ban unattended-upgrades`.

## Useful commands

```bash
# Stop paying for compute without deleting anything (the static IP is still billed)
az vm deallocate -g $RG -n $VM
az vm start -g $RG -n $VM

# Show everything in the environment
az resource list -g $RG --output table

# Delete the WHOLE environment (irreversible)
az group delete --name $RG --yes --no-wait
```

## Troubleshooting

| Problem | Fix |
|---|---|
| `SkuNotAvailable` / quota error on `az vm create` | Change `VM_SIZE` or `LOCATION` (section 2). |
| `Permission denied (publickey)` | Use the same key you passed in `--ssh-key-values`; try `ssh -i <path-to-private-key> ...`. |
| SSH times out | Check the NSG rules (`az network nsg rule list -g $RG --nsg-name $NSG -o table`). |
| `docker context` says `permission denied` on the socket | You skipped `usermod -aG docker` or did not log out and back in. |
| Services killed / VM unresponsive | Out of memory: use a bigger size or confirm swap is on (`free -h`). |
| IP changed after deallocate | It should not with a Static IP; if DuckDNS is wrong, update it. |

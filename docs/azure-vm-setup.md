# Azure VM Setup with Azure CLI

Step-by-step guide to create the VM that hosts the Snippet Searcher Docker
Swarm stack. Everything is done with the Azure CLI (`az`) and plain shell
commands, so every step can be read, copied and repeated by anyone.

The result is **one Ubuntu VM** that is a **single-node Docker Swarm
manager**, with a static public IP and ports `22`, `80` and `443` open.
Repeat the guide once per environment (`dev` and `prod`).

## 0. Decisions

| Item | Value | Notes |
|---|---|---|
| OS | Ubuntu Server 22.04 LTS | |
| Size | `Standard_B2s` (2 vCPU, 4 GB RAM) | The stack runs 7 containers (two Spring apps, two Postgres, Azurite, two Nginx). `Standard_B1s` (1 GB) is too small. |
| Disk | 30 GB Standard SSD | Volumes (Postgres, Azurite) live here. |
| Swarm | Single manager | No workers needed. |
| Open ports | 22, 80, 443 | Never expose Docker's 2375/2376. |
| Auth | SSH key only | No passwords. |

> **Azure for Students:** some sizes/regions are blocked for your
> subscription. If `az vm create` fails with `SkuNotAvailable` or a quota
> error, list what you can use (section 2) and change `VM_SIZE` / `LOCATION`.

## 1. Prerequisites (on your own machine)

1. Install the Azure CLI:
- For linux use: <https://learn.microsoft.com/cli/azure/install-azure-cli-linux>
- For windows use: <https://learn.microsoft.com/cli/azure/install-azure-cli-windows>

2. Log in and pick the subscription:

   ```bash
   az login
   az account list --output table
   az account set --subscription "<SUBSCRIPTION_NAME_OR_ID>"
   ```

3. Have an SSH key (create one if `ls <path-to-your-public-key.pub>` fails):

   ```bash
   ssh-keygen -t ed25519 -C "<comment>" -f <path-to-new-key>
   ```

   Only the **public** key (`.pub`) goes to Azure. Never share the private key.

## 2. Check what you are allowed to create

```bash
az vm list-skus --location eastus --size Standard_B2 --output table
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

GitHub-hosted runners have no fixed IP, so a GitHub Actions deploy over SSH
cannot pass this restriction. Options: temporarily add the runner IP in the
workflow and remove it afterwards, or use a self-hosted runner. Always use a
dedicated deploy key, never your personal one.

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
ssh $ADMIN_USER@$VM_IP
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
git clone <URL-OF-THIS-REPOSITORY>
cd snippet-infra
```

## 9. Log in to GitHub Container Registry (inside the VM)

Images are pulled from GHCR. Create a GitHub personal access token with
only the `read:packages` scope, then:

```bash
echo "<TOKEN>" | docker login ghcr.io -u <GITHUB_USER> --password-stdin
```

`scripts/deploy.sh` uses `--with-registry-auth`, so Swarm reuses this login.

## 10. Manage the VM remotely with Docker Context (on your machine)

This lets you run `docker` commands against the VM over SSH, without
exposing the Docker API:

```bash
docker context create snippet-$ENV --docker "host=ssh://$ADMIN_USER@$VM_IP"
docker --context snippet-$ENV node ls      # shows the VM's Swarm node
docker context use snippet-$ENV            # make it the default (docker context use default to go back)
```

## 11. Next steps

1. Deploy the stack and issue the certificate: follow *Let's Encrypt* in
   [`README.md`](../README.md).
2. GitHub Actions deploy: store the SSH **private** key as a GitHub secret,
   create the Docker context in the workflow with the same
   `ssh://<ADMIN_USER>@<VM_IP>` host, and run `scripts/deploy.sh`.

## Security notes

- Never commit private keys, tokens, `azure-vm.env` or Azure IDs.
- The GHCR token needs only `read:packages`; store it in a password manager.
- Password login is disabled; SSH is key-only and limited to one IP.
- Optional hardening inside the VM: `sudo apt-get install -y fail2ban
  unattended-upgrades`.

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

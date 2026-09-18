# samba

Servidor de arquivos via SMB, rodando no cluster k8s (`vm-ubuntu`, 192.168.0.5),
substituindo o TrueNAS que existia antes só pra isso. Serve o pool ZFS
`diegofnunesbr`, criado direto no disco de 2TB em passthrough (sem TrueNAS
por cima), com compressão LZ4 ligada.

## 0. Passthrough do disco (host Proxmox, 192.168.0.3)

Se o disco de 2TB ainda estiver preso a outra VM (ex.: uma VM de storage
antiga), primeiro desliga ela e remove o passthrough:

```bash
sudo qm shutdown <VMID_ANTIGO>
sudo qm set <VMID_ANTIGO> -delete scsi1
```

Confirma o id do disco e anexa na VM que vai rodar o cluster (aqui,
101 = vm-ubuntu):

```bash
ls /dev/disk/by-id | grep ADATA
sudo qm set 101 -scsi1 /dev/disk/by-id/nvme-ADATA_LEGEND_860_2P192L2K71XR
```

O disco aparece dentro da VM sem precisar reiniciar (hot-plug). Confirme
com `lsblk` (deve aparecer como `sdb`, ~1.8T).

## 1. Preparar o disco e criar o pool ZFS (dentro da vm-ubuntu)

**Atenção: isso apaga qualquer dado/assinatura existente no disco.**

```bash
sudo blkid /dev/sdb /dev/sdb1        # confere o que tem lá antes de apagar
sudo wipefs -a /dev/sdb

sudo apt-get install -y zfsutils-linux

# path estável do disco (não muda entre reboots, ao contrário de /dev/sdb)
ls -la /dev/disk/by-id/ | grep scsi1

sudo zpool create -o ashift=12 -O compression=lz4 -O xattr=sa \
  diegofnunesbr /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi1

# dataset separado só pra base de contas do Samba, fora do compartilhamento
sudo zfs create -o mountpoint=/var/lib/samba-config diegofnunesbr/samba-config

sudo zpool status diegofnunesbr
sudo zfs list
```

## 2. sealed-secrets (só na primeira vez que configurar esse cluster)

Se o cluster ainda não tiver o controller (`kubectl get pods -n kube-system
| grep sealed` não retorna nada):

```bash
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.40.0/controller.yaml
kubectl rollout status deployment/sealed-secrets-controller -n kube-system --timeout=60s

curl -sL https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.40.0/kubeseal-0.40.0-linux-amd64.tar.gz -o /tmp/kubeseal.tar.gz
tar -xzf /tmp/kubeseal.tar.gz -C /tmp kubeseal
sudo install -m 755 /tmp/kubeseal /usr/local/bin/kubeseal
```

## 3. Build da imagem

Rodar dentro da pasta do projeto, na própria vm-ubuntu (é lá que o
`docker build` e o `k0s ctr` precisam rodar):

```bash
docker build -t samba/server:latest .
docker save samba/server:latest | sudo k0s ctr images import -
```

## 4. Secrets

**Nunca edite `k8s/secrets.example.yaml` com valores reais** - é só o
template. Copie para um arquivo à parte (coberto pelo `.gitignore`):

```bash
cp k8s/secrets.example.yaml k8s/secrets.local.yaml
openssl rand -hex 16   # gera a senha, cole em smb-password no arquivo
```

Sele com kubeseal (`--scope cluster-wide`, formato yaml):

```bash
kubectl apply -f k8s/namespace.yaml   # precisa existir antes de selar (o scope é por namespace)
kubeseal --scope cluster-wide --format yaml < k8s/secrets.local.yaml > k8s/secrets.sealed.yaml
kubectl apply -f k8s/secrets.sealed.yaml
```

`secrets.local.yaml` nunca vai pro git (`*.local.yaml` no `.gitignore`),
mesmo selado - fica só local. `secrets.sealed.yaml` (o resultado do
kubeseal) pode ir pro git normalmente, é seguro por ser criptografado.

## 5. Deploy

```bash
kubectl apply -f k8s/samba.yaml
kubectl -n samba rollout status deployment/samba --timeout=60s
```

Conferir se subiu certo:

```bash
kubectl -n samba logs deployment/samba --tail=20
sudo ss -tlnp | grep 445   # confirma smbd escutando
sudo ls -la /var/lib/samba-config/private/   # confirma persistência do passdb
```

## Acesso

Do Windows, `\\192.168.0.5\diegofnunesbr`, autenticando com o usuário
`diegofnunesbr` e a senha configurada no secret.

## Trocar a senha depois

A conta é recriada/sincronizada a cada start do pod a partir do
`SMB_PASSWORD` do secret (a base em si, `/var/lib/samba`, é persistida em
disco - só a senha é sempre re-sincronizada). Pra trocar:

1. Editar `smb-password` em `k8s/secrets.local.yaml`.
2. Repetir o `kubeseal`/`kubectl apply` do passo 4.
3. `kubectl -n samba rollout restart deployment/samba`

## Snapshots

Não configurados ainda - próximo passo é um cron de `zfs snapshot` no pool
`diegofnunesbr`.

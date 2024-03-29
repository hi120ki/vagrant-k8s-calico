#!/bin/bash -eu

cd $(dirname $0)

cmd=$(basename $0)
if [ $# -ne 1 ]; then
  echo "Usage: $cmd address" 1>&2
  exit 1
fi

sudo snap install yq

echo "[i] install helm"
cd ~
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh

echo "[i] add shell alias"
# https://github.com/ahmetb/kubectl-aliases
curl -fsSL "https://raw.githubusercontent.com/ahmetb/kubectl-aliases/master/.kubectl_aliases" -o ~/.kubectl_aliases
echo '[ -f ~/.kubectl_aliases ] && source ~/.kubectl_aliases' >>~/.bashrc
echo 'function kubectl() { echo "+ kubectl $@">&2; command kubectl $@; }' >>~/.bashrc
if [ -f ~/.config/fish/config.fish ]; then
  curl -fsSL "https://raw.githubusercontent.com/ahmetb/kubectl-aliases/master/.kubectl_aliases.fish" -o ~/.kubectl_aliases.fish
  echo 'test -f ~/.kubectl_aliases.fish && source ~/.kubectl_aliases.fish' >>~/.config/fish/config.fish
fi

# https://kubernetes.io/docs/setup/production-environment/container-runtimes/#install-and-configure-prerequisites
echo "[i] network config"
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system
sysctl net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables net.ipv4.ip_forward

echo "[i] install containerd"
sudo apt-get update && sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
sudo add-apt-repository \
  "deb [arch=amd64] https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) \
    stable"
sudo apt-get update && sudo apt-get install -y containerd.io
sudo mkdir -p /etc/containerd
containerd config default | sed -e "s/SystemdCgroup = false/SystemdCgroup = true/g" | sudo tee /etc/containerd/config.toml
sudo systemctl restart containerd

echo "[i] install kubeadm"
sudo apt-get update && sudo apt-get install -y apt-transport-https curl
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
cat <<EOF | sudo tee /etc/apt/sources.list.d/kubernetes.list
deb https://apt.kubernetes.io/ kubernetes-xenial main
EOF
sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

echo "[i] restart containerd"
sudo rm /etc/containerd/config.toml
sudo systemctl restart containerd

echo "[i] kubeadm init"
sudo kubeadm init --pod-network-cidr=192.168.0.0/16 --apiserver-advertise-address $1

mkdir -p $HOME/.kube
sudo cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

for i in {10..1}; do
  echo "[i] waiting kubeadm init $i"
  sleep 1
done

c1=$(kubectl get pods -A | grep -c "Running") || true
c2=$(kubectl get pods -A | grep -c "Pending") || true
while [ $c1 -ne 5 ] || [ $c2 -ne 2 ]
do
  sleep 1
  echo "[i] waiting coredns pending"
  c1=$(kubectl get pods -A | grep -c "Running") || true
  c2=$(kubectl get pods -A | grep -c "Pending") || true
done
sleep 3
echo "[+] coredns pending done"

echo "[i] install calico"
# https://projectcalico.docs.tigera.io/getting-started/kubernetes/quickstart
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.25.1/manifests/tigera-operator.yaml

c1=$(kubectl get pods -A | grep -c "Running") || true
c2=$(kubectl get pods -A | grep -c "Pending") || true
while [ $c1 -ne 6 ] || [ $c2 -ne 2 ]
do
  sleep 1
  echo "[i] waiting tigera-operator running"
  c1=$(kubectl get pods -A | grep -c "Running") || true
  c2=$(kubectl get pods -A | grep -c "Pending") || true
done
sleep 3
echo "[+] tigera-operator running done"

kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.25.1/manifests/custom-resources.yaml

c1=$(kubectl get pods -A | grep -c "Running") || true
c2=$(kubectl get pods -A | grep -c "Pending") || true
while [ $c1 -ne 14 ] || [ $c2 -ne 0 ]
do
  sleep 1
  echo "[i] waiting custom-resources running"
  c1=$(kubectl get pods -A | grep -c "Running") || true
  c2=$(kubectl get pods -A | grep -c "Pending") || true
done
sleep 3
echo "[+] custom-resources running done"

echo "[i] taint node"
kubectl taint node --all node-role.kubernetes.io/control-plane:NoSchedule-

echo "[i] node info"
kubectl get nodes -o wide

echo "[i] install calicoctl"
# https://projectcalico.docs.tigera.io/maintenance/clis/calicoctl/install
sudo curl -fsSL https://github.com/projectcalico/calico/releases/download/v3.25.1/calicoctl-linux-amd64 -o /usr/local/bin/calicoctl
sudo chmod +x /usr/local/bin/calicoctl
sudo curl -fsSL https://github.com/projectcalico/calico/releases/download/v3.25.1/calicoctl-linux-amd64 -o /usr/local/bin/kubectl-calico
sudo chmod +x /usr/local/bin/kubectl-calico
kubectl calico -h

echo "[i] enable hostpath provisioner"
sudo cat /etc/kubernetes/manifests/kube-controller-manager.yaml |
  yq -e '.spec.containers[].command += ["--enable-hostpath-provisioner=true"]' |
  sudo tee /etc/kubernetes/manifests/kube-controller-manager.yaml

echo "[i] add storageclass"
cat <<EOF | kubectl apply -f -
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: standard
  annotations:
    storageclass.beta.kubernetes.io/is-default-class: "true"
provisioner: kubernetes.io/host-path
EOF

echo "[+] All Done"

#!/bin/bash -eu

cd $(dirname $0)

echo "[i] install helm"
cd ~ ; curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 ; chmod 700 get_helm.sh ; ./get_helm.sh

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

sudo apt-get update
sudo apt-get install -y iptables arptables ebtables
sudo update-alternatives --set iptables /usr/sbin/iptables-legacy
sudo update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
sudo update-alternatives --set arptables /usr/sbin/arptables-legacy
sudo update-alternatives --set ebtables /usr/sbin/ebtables-legacy

echo "[i] install containerd"
sudo apt-get update && sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
sudo add-apt-repository \
    "deb [arch=amd64] https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) \
    stable"
sudo apt-get update && sudo apt-get install -y containerd.io
sudo mkdir -p /etc/containerd
containerd config default | sed -e "s/systemd_cgroup = false/systemd_cgroup = true/g" | sudo tee /etc/containerd/config.toml
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
sudo kubeadm init --pod-network-cidr=192.168.0.0/16 --apiserver-advertise-address 192.168.56.210

mkdir -p $HOME/.kube
sudo cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

for i in {10..1}; do
  echo "[i] waiting kubeadm init $i"
  sleep 1
done

c1=$(kubectl get pods -A | grep -c "Running")
c2=$(kubectl get pods -A | grep -c "Pending")
while [ $c1 -ne 5 ] || [ $c2 -ne 2 ]
do
  sleep 1
  echo "[i] waiting coredns pending"
  c1=$(kubectl get pods -A | grep -c "Running")
  c2=$(kubectl get pods -A | grep -c "Pending")
done
sleep 3
echo "[+] coredns pending done"

kubectl create -f https://projectcalico.docs.tigera.io/manifests/tigera-operator.yaml

c1=$(kubectl get pods -A | grep -c "Running")
c2=$(kubectl get pods -A | grep -c "Pending")
while [ $c1 -ne 6 ] || [ $c2 -ne 2 ]
do
  sleep 1
  echo "[i] waiting tigera-operator running"
  c1=$(kubectl get pods -A | grep -c "Running")
  c2=$(kubectl get pods -A | grep -c "Pending")
done
sleep 3
echo "[+] tigera-operator running done"

kubectl create -f https://projectcalico.docs.tigera.io/manifests/custom-resources.yaml

c1=$(kubectl get pods -A | grep -c "Running")
c2=$(kubectl get pods -A | grep -c "Pending")
while [ $c1 -ne 10 ] || [ $c2 -ne 1 ]
do
  sleep 1
  echo "[i] waiting custom-resources running"
  c1=$(kubectl get pods -A | grep -c "Running")
  c2=$(kubectl get pods -A | grep -c "Pending")
done
sleep 3
echo "[+] custom-resources running done"

kubectl taint node --all node-role.kubernetes.io/control-plane:NoSchedule-

c1=$(kubectl get pods -A | grep -c "Running")
c2=$(kubectl get pods -A | grep -c "Pending")
while [ $c1 -ne 11 ] || [ $c2 -ne 0 ]
do
  sleep 1
  echo "[i] waiting calico running"
  c1=$(kubectl get pods -A | grep -c "Running")
  c2=$(kubectl get pods -A | grep -c "Pending")
done
sleep 3
echo "[+] calico running done"

kubectl taint nodes --all node-role.kubernetes.io/master-

kubectl get nodes -o wide

echo "[+] all done"

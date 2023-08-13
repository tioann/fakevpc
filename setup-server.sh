#!/bin/bash
set -xe

IDX=$1
SERVER=server${IDX}

qemu-img create -f qcow2 -F qcow2 -b jammy-server-cloudimg-amd64.img $SERVER.img 40G

cat > userdata-$SERVER.yaml <<EOF
#cloud-config

hostname: $SERVER
fqdn: $SERVER.localdomain
manage_etc_hosts: true

ssh_pwauth: false
disable_root: true

users:
  - name: ubuntu
    home: /home/ubuntu
    shell: /bin/bash
    groups: sudo
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh-authorized-keys:
      - $(cat sshkey.pub)
EOF

cloud-localds userdata-$SERVER.iso userdata-$SERVER.yaml

qemu-system-x86_64 \
      -nodefaults -no-user-config -nographic \
      -net nic \
      -net user,hostfwd=tcp:127.0.0.1:$((5000 + $IDX))-:22,hostfwd=udp:127.0.0.1:$((51820 + $IDX))-:$((51820 + $IDX)) \
      -enable-kvm \
      -cpu host \
      -m 1024 \
      -smp 2 \
      -hda $SERVER.img \
      -cdrom userdata-$SERVER.iso &

timeout 120s bash -c "while true ; do timeout 10s ssh -i sshkey -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o Port=$(( 5000 + $IDX )) ubuntu@127.0.0.1 echo '$SERVER ready' && break ; sleep 1 ; done"

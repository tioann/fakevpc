# Fake VPC

TL;DR: Setup wireguard for communications between servers, simulating a VPC.

For multi-server setups, VPCs are a pretty big deal. A VPC between servers allows direct communication with minimal overhead and relaxed security concerns. Cloud vendors offer ready-made solutions within their infrastructure for VPCs but this is unavailable (or costlier) when servers are in different providers or on-premises. This document describes a simple, zero-cost solution for such cases.

This solution is recommended for a small number of servers, probably single-digit numbers.

# Requirements

The VPC-like solution should support the following features:

- secure, encrypted communications between any pair of servers
- failure or network disconnection of any server should not impact the communication between any other online and functioning pair of servers
- adjustable, easy to add and remove servers as needed
- work across different cloud providers and arbitrary server locations

Some assumptions are also made:

- servers are able to communicate between them using UDP (wireguard uses this)
- root access to the servers is available
- OS is ubuntu/linux (but should easily be adaptable for e.g. Windows)

# Network setup

The VPC described here consists of a total of 5 servers, named server1 to server5, indexed from 1 to 5. Each of the servers will be running a wireguard interface in server mode and a number of wireguard interfaces in client mode. The wireguard clients depend on the server index:

- server1 will run a wireguard server and no clients
- server2 will run a wireguard server and one wireguard client to connect to server1
- server3 will run a wireguard server and two wireguard clients to connect to server1 and server2
- ... and so on

In general, serverN will use N-1 wireguard clients to connect to server1 up to server(N-1).

IP addresses are assigned to these interfaces as follows:

- the wireguard server on serverN will use the IP address `192.168.N.1`
- the wireguard client of serverM will connect to the wireguard serverN (where M>N) with an IP address of `192.168.N.M`
- for simplicity the `/etc/hosts` files on each server will be updated to specify proper IP addresses for the names server1 to server5

The rule for serverA to talk to serverB is therefore:

- if A > B, serverA will use IP address `192.168.B.1` to talk to serverB
- if A < B, serverA will use IP address `192.168.A.B` to talk to serverB
- if A = B, serverA will use IP address `127.0.0.1` to talk to itself

One final detail is about running services inside the VPC that we want to only be available within the VPC and not exposed to the internet in general (e.g. running a database). Some of the services such as SSH support specifying multiple IP addresses to bind to, which makes things very simple. Some other services however only support specifying a single IP or all IPs. In such cases, it is recommended to start a service listening on `127.0.0.1` and handle the additional interfaces in two ways:

- use iptables rules to redirect requests from other IP addresses
- use socat to redirect requests from other IP addresses

The iptables alternative should be used when high performance is required, socat can be used for simplicity.

# Additional features

One possibility for such a setup is when some of the servers are not reachable over the public internet, e.g. are located inside a private network. For example having 3 servers, 2 of which are on a cloud provider and accessible via public IP addresses and one server at a home network for fast access. By assigning server3 to the internal server, the setup as described will work with zero changes and allow server3 access at max speed from the private network clients.

# Sample implementation

## Preparation

For this example, local VMs are used to setup an example with 3 servers. This part would be replaced on a proper setup with setting up cloud VMs so we only present here a simple setup based on qemu/kvm.

To avoid polluting the local system, a qemu handler VM will be used to do all of the configuration work and packages installation. The VPC server VMs will be siblings to the handler VM as there is already qemu installed on the host system.

### Start the handler VM

1. Install needed packages on the host and make sure the current user belongs to the kvm group:

    ```
    sudo apt install curl qemu-utils cloud-image-utils qemu qemu-kvm bridge-utils
    usermod -a -G kvm $USER
    ```

1. Create a working dir on the host. All updates will be strictly limited inside this dir.

    ```
    mkdir -p ~/projects/fakevpc
    cd ~/projects/fakevpc
    ```

1. Create an ssh key that will be used for accessing the VMs via SSH (unencrypted):

    ```
    ssh-keygen -t ed25519 -N '' -f sshkey
    ```

1. Download an ubuntu 22.04 cloud image for the VMs. Adjust as needed for arm64 or other flavours.

    ```
    curl -L https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img -o jammy-server-cloudimg-amd64.img
    ```
    
1. Create a qcow2 image for the handler VM, based on the downloaded cloud image. This allows reusing the cloud image by all VMs.

    ```
    qemu-img create -f qcow2 -F qcow2 -b jammy-server-cloudimg-amd64.img handler.img 40G
    ```

1. Configure the handler VM to allow SSH using the key just created:

    ```
    cat > userdata-handler.yaml <<EOF
    #cloud-config

    hostname: handler
    fqdn: handler.localdomain
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

    cloud-localds userdata-handler.iso userdata-handler.yaml
    ```

1. Start the handler using qemu:

    ```
    qemu-system-x86_64 \
      -nodefaults -no-user-config -nographic \
      -net nic \
      -net user,hostfwd=tcp:127.0.0.1:5000-:22 \
      -enable-kvm \
      -cpu host \
      -m 1024 \
      -smp 2 \
      -hda handler.img \
      -cdrom userdata-handler.iso &
    ```

1. After waiting for 1 minute for the handler to spin up, try to SSH into the handler to verify that all is good:

    ```
    ssh -i sshkey -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o Port=5000 ubuntu@127.0.0.1
    ```

1. Inside the handler VM, install needed software:

    ```
    sudo apt update
    sudo apt upgrade -y
    sudo apt install -y python3-pip python3-venv
    python3 -m venv venv
    venv/bin/pip install --upgrade pip
    venv/bin/pip install ansible-core
    venv/bin/ansible-galaxy collection install ansible.utils
    ```

### Start the servers

The setup for each of the server VMs is very similar to the handler VM and there is a bash script that automates the process:

    ./setup-server.sh 1
    ./setup-server.sh 2
    ./setup-server.sh 3

Each `./setup-server.sh` command will wait for the VM to become available (accessible via SSH) before terminating, with a timeout of 120 seconds.

For each server, qemu is configured with user networking which means the VMs don't get individual IP addresses. Instead, a couple of host ports ad specified that are forwarded to specific ports in the VMs (TCP ports 5000+ for SSH access to the VMs and UDP ports 51821+ for use by wireguard). The VMs themselves can access all host ports by using the 10.0.2.2 IP address and can therefore also talk to each other.

### Install fakevpc on the servers

An ansible script `setup-fakevpc.yaml` is provided to do all the configuration for setting up the wireguard networking as previously described. The script contains a number of variables that can be adjusted:

- `update_upgrade_servers`: This is used to make sure the servers are up-to-date, useful for fresh installs. Setting to true will also do a server reboot if any updates have been applied.
- `iface_ip_offset`: This is a value that indicates the start of the 192.168.x.0/24 ranges to be used by the wireguard interfaces. Useful for cases where the 192.168.1.0/24 subnet is already allocated, by setting this to e.g. 5 then wireguard will use subnets from 192.168.5.1/16 onwards.
- `servers`: A dictionary for server connection attributes, used by both ansible to setup the SSH connections as well as connections between the servers. Each server gets a name (`server1`, `server2`, ...) as well as the following parameters:
    - `address`: The IP address used to access the server from any external system and is typically the public IP address.
    - `ssh_port`: The port used for SSH access to the server. This is used because the qemu user networking forces us to use different ports for each server as they all have the same IP address.
    - `wg_port`: The UDP port used for wireguard communications from any external system. The same wireguard listening port as the VM forwarding port is used for clarity and flexibility.

Once the server VMs are up and running, the ansible script is executed from within the handler VM:

1. From the host, copy the SSH key and the script to the handler VM:

        scp -i sshkey -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o Port=5000 sshkey ubuntu@127.0.0.1:
        scp -i sshkey -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o Port=5000 setup-fakevpc.yaml ubuntu@127.0.0.1:

1. Inside the handler VM, run the script:

        venv/bin/ansible-playbook -vv setup-fakevpc.yaml

Once the script completes successfully, the fake VPC setup is complete :-D

To verify that the setup is proper, try a few ping commands from one server to another by using their VPC names (`server1`, `server2`, ...).

Rerunning the script can be done at any time without affecting the existing connections unless any configuration changes are made (such as adding or removing servers). Additionally, any server restart will automatically reconnect to the fake VPC.

Note that the script will generate private wireguard key files in the handler (`server1-wg-key-private`, `server2-wg-key-private` and so on). These should be preserved if it is desirable for redeployments to not interrupt any networking.

## Running a VPC-only service

A simple echo server is deployed that will only be accessible from the VPC servers but no external entities, provided by server2. This is configured as the final part of the `setup-fakevpc.yaml` file.

The service is listening on server2, bound on 127.0.0.1 port 8888 so by default is not visible by any other server. To allow other VPC servers to access it socat is used to do port forwarding from other interfaces. A server with index `i` (`i` is from 1 to N) needs to forward requests for each of the wireguard client interfaces it uses for connecting to each of the servers `server1`, `server2`, ..., `server(i-1)` plus the wireguard server interface it uses to connect to servers `server(i+1)`, `server(i+2)`, ..., `serverN`. Forwardind in the script is done using the `socat` utility.

Testing the service from any of the VPC servers (including itself) is pretty simple:

```
echo "123" | nc -N server2.vpcdomain 8888
```

NOTE: The main reason the .vpcdomain is introduced is because the unqualified `server2` name works from all other VPC servers except itself because it resolves by default to 127.0.1.1 which does not connect to myecho service which listens on 127.0.0.1. Using `server2.vpcdomain` fixes this.

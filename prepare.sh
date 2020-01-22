#!/usr/bin/env bash

apt-get install -yy sharutils 

cat > setup-home-pal.sh <<EOF
#!/bin/sh
apt install -yy uuid curl jq sysstat tcpdump nmap python3-pip
pip3 install yq
pip3 install esphome
PALDIR=/tmp/home-pal-\$(uuid)
echo USE Tempdir: \$PALDIR
mkdir -p \$PALDIR
cd \$PALDIR

( $(shar $(find templates -type f)) )

CLUSTERNAME=\$(hostname)
echo -n "clustername [\$CLUSTERNAME]:"
read cluster_name
if [ -n "\$cluster_name" ]
then
  CLUSTERNAME=\$cluster_name
fi
echo SetHostname: \$CLUSTERNAME
hostnamectl set-hostname \$CLUSTERNAME
sed -i'.home-pal' "s/^127.0.1.1.*\$/127.0.1.1 \$CLUSTERNAME/" /etc/hosts

TIMEZONE=MET
echo -n "timezone [\$TIMEZONE]:"
read timezone
if [ -n "\$timezone" ]
then
  TIMEZONE=\$timezone
fi
echo SetTimezone: \$TIMEZONE
timedatectl set-timezone \$TIMEZONE
timedatectl set-ntp true

echo 'Change swapsize to 1GB'
sed -i'.home-pal' 's/^CONF_SWAPSIZE=.*/CONF_SWAPSIZE=1024/' /etc/dphys-swapfile

BASEDIR=/\$CLUSTERNAME
echo "Prepare pods local data directories: [\$BASEDIR]"
mkdir -p \$BASEDIR

for unit in \$(cd templates && find etc -type f)
do
  destUnit=/\$unit
  echo "Deploy Unit: [\$destUnit]"
  mkdir -p \$(dirname \$destUnit)
  sed \
    -e "s/%CLUSTERNAME%/\$CLUSTERNAME/g" \
    -e "s/%BASEDIR%/\$(echo \$BASEDIR | sed 's/\\//\\\\\\//')/g" \
    templates/\$unit > \$destUnit
  if [ "\$(basename \$destUnit)" = "esphome.service" ]
  then
    mkdir -p \$BASEDIR/esphome
    systemctl daemon-reload
    systemctl enable esphome.service
    systemctl stop esphome.service
    systemctl start esphome.service
  fi
done

kubectl get nodes 2> /dev/null | grep -e '^\$CLUSTERNAME\s\s*Ready'
if [ $? -ne 0 ]
then
  curl -sfL https://get.k3s.io | sh -
  ready=0
  while [ \$ready -eq 0 ]
  do
    kubectl get nodes 2> /dev/null | grep -e '^\$CLUSTERNAME\s\s*Ready'
    if [ $? -eq 0 ]
    then
      ready=1 
    else
      echo "waiting for k3s startup"
      sleep 1
    fi
  done
fi

#templates/etc/systemd/system/teleport.service:   --token=%TELEPORT_TOKEN% \
#templates/etc/systemd/system/teleport.service:   --ca-pin=%TELEPORT_CA_PIN% \

#templates/pods/influx-db.yaml:      path: /%BASEDIR%/influx-db
#templates/pods/influx-db.yaml:      path: /%BASEDIR%/chronograf
#templates/pods/zigbee2mqtt.yaml:      path: /%BASEDIR%/zigbee2mqtt
#templates/pods/node-red.yaml:      path: /%BASEDIR%/node-red
#templates/pods/hass-io.yaml:      path: /%BASEDIR%/hass.io
#templates/pods/teleport.yaml:  name: teleport-%CLUSTERNAME%
#templates/pods/teleport.yaml:    run: teleport-%CLUSTERNAME%
#templates/pods/teleport.yaml:      path: /%BASEDIR%/teleport/teleport.yaml
#templates/pods/teleport.yaml:      path: /%BASEDIR%/teleport/lib
#templates/pods/teleport.yaml:  name: teleport-%CLUSTERNAME%
#templates/pods/teleport.yaml:    run: teleport-%CLUSTERNAME%

for pod in \$(find templates/pods -type f)
do
 destPodYaml="\$BASEDIR/\$(basename \$pod)"
 if [ -f "\$destPodYaml" ]
 then
   mv "\$destPodYaml" "\$destPodYaml".home-pal
 fi
 sed \
   -e "s/%BASEDIR%/\$(echo \$BASEDIR | sed 's/\\//\\\\\\//')/g" \
   -e "s/%CLUSTERNAME%/\$CLUSTERNAME/g" \
   \$pod > "\$destPodYaml"
 podName=\$(yq -r '(select(.kind=="Pod")) | .metadata.name' "\$destPodYaml")
 echo "Prepare and deploy: [\$destPodYaml][\$podName]"
   if [ \$(basename \$pod .yaml) = 'node-red' ]
   then
     echo Spezial node-red
     mkdir -p \$BASEDIR/node-red
     chown -R 1000:1000 \$BASEDIR/node-red
   fi
   applyJoinToken=0
   if [ \$(basename \$pod .yaml) = 'teleport' ]
   then
     echo "Add trusted cluster teleport.adviser.com"
     echo " run: tctl tokens add --type=trusted_cluster --ttl=5m"
     echo -n "JoinToken:" 
     read jointoken
     if [ -n "\$jointoken" ]
     then
       echo "Set Join Token: [\$jointoken]"
       sed -i.home-pal "s/%CLUSTERTOKEN%/\$jointoken/g" "\$destPodYaml" 
       applyJoinToken=1
     fi
   fi
   kubectl get "pod/\$podName" 2> /dev/null
   if [ \$? = 0 ]
   then
     echo "Delete Running Pod [\$destPodYaml]"
     kubectl delete -f "\$destPodYaml"
   fi
   kubectl apply -f "\$destPodYaml"
   ready=0
   while [ \$ready -eq 0 -a \$(basename \$pod .yaml) = 'teleport' -a \$applyJoinToken -eq 1 ]
   do
      kubectl exec -ti "pod/\$podName" tctl help > /dev/null 2> /dev/null
      if [ \$? -eq 0 ]
      then
        echo "Add to Trusted cluster teleport.adviser.com"
        kubectl exec -ti "pod/\$podName" tctl rm cluster/adviser.com
        kubectl exec -ti "pod/\$podName" tctl create /etc/teleport/adviser.com-cluster.yaml
        ready=1
      else
        sleep 1
      fi
   done
done

if [ ! -f /usr/local/bin/teleport ]
then
  echo "install teleport client on host"
  curl https://get.gravitational.com/teleport-v4.2.2-linux-arm-bin.tar.gz | tar xzf -
  cd teleport && ./install
fi

if [ ! -f /etc/systemd/system/teleport.service.d/pins.conf ]
then
  ready=0
  while [ \$ready -eq 0 ]
  do
    kubectl exec -ti pod/teleport-bz-horst tctl nodes add 2> /dev/null > nodes-add.out
    if [ \$? -eq 0 ]
    then
      ready=1
      token=\$(grep -- '--token=' nodes-add.out | sed 's/^.*--token=\(\S\S*\).*\$/\1/')
      ca_pin=\$(grep -- '--ca-pin=' nodes-add.out | sed 's/^.*--ca-pin=\(\S\S*\).*\$/\1/')
      echo "Token:\$token"
      echo "ca_pin:\$ca_pin"
      mkdir -p /etc/systemd/system/teleport.service.d
      cat > /etc/systemd/system/teleport.service.d/pins.conf <<ENVEOF
[Service]
Environment=TELEPORT_TOKEN=\$token
Environment=TELEPORT_CA_PIN=\$ca_pin
ENVEOF
      systemctl daemon-reload
      systemctl enable teleport.service
      systemctl stop teleport.service
      systemctl start teleport.service
    else
       sleep 1
    fi
  done
fi

EOF

chmod 755 ./setup-home-pal.sh


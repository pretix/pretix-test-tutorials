#!/bin/bash
set -e
set -v
export DEBIAN_FRONTEND=noninteractive
export TAG=stable
MYSQL_PASSWD=L2zOgq6kTHdmaE0g1rMBjMTuksXvzq

# This follows https://docs.pretix.eu/en/latest/admin/installation/docker_smallscale.html
# as closely as possible
# Currently missing: mail setup, cronjob and SSL

# Install docker
apt-get -y install \
    apt-transport-https \
    ca-certificates \
    curl \
    software-properties-common
curl -fsSL https://download.docker.com/linux/$(. /etc/os-release; echo "$ID")/gpg | sudo apt-key add -
add-apt-repository \
	"deb [arch=amd64] https://download.docker.com/linux/$(. /etc/os-release; echo "$ID") \
	$(lsb_release -cs) \
	stable"
apt-get -y update
apt-get -y install docker-ce

# Install MariaDB
apt-get install software-properties-common
apt-key adv --recv-keys --keyserver keyserver.ubuntu.com 0xcbcb082a1bb943db
add-apt-repository 'deb [arch=amd64,i386,ppc64el] http://mirror.one.com/mariadb/repo/10.4/debian jessie main'
apt-get -y update
apt-get -y install mariadb-server

# Install redis
apt-get -y install redis-server

# Data files
mkdir /var/pretix-data
chown -R 15371:15371 /var/pretix-data

# Database
mysql -e "CREATE DATABASE pretix DEFAULT CHARACTER SET utf8 DEFAULT COLLATE utf8_general_ci;"
mysql -e "GRANT ALL PRIVILEGES ON pretix.* TO pretix@'localhost' IDENTIFIED BY '$MYSQL_PASSWD';"
mysql -e "FLUSH PRIVILEGES;"

# Redis
echo "" >> /etc/redis/redis.conf
echo "unixsocket /var/run/redis/redis.sock" >> /etc/redis/redis.conf
echo "unixsocketperm 777" >> /etc/redis/redis.conf
systemctl restart redis-server

# pretix config file
mkdir /etc/pretix
touch /etc/pretix/pretix.cfg
chown -R 15371:15371 /etc/pretix
chmod 0700 /etc/pretix/pretix.cfg
cat << EOF > /etc/pretix/pretix.cfg
[pretix]
instance_name=pretixtest.local
url=http://pretixtest.local
currency=EUR
datadir=/data

[database]
backend=mysql
name=pretix
user=pretix
password=$MYSQL_PASSWD
host=/var/run/mysqld/mysqld.sock

[mail]
from=tickets@pretixtest.local
host=172.17.0.1  ; postfix isn't actually set up in this script, so mails will fail

[redis]
location=unix:///var/run/redis/redis.sock?db=0
sessions=true

[celery]
backend=redis+socket:///var/run/redis/redis.sock?virtual_host=1
broker=redis+socket:///var/run/redis/redis.sock?virtual_host=2
EOF

# Docker image and service
docker pull pretix/standalone:$TAG

cat << EOF > /etc/systemd/system/pretix.service
[Unit]
Description=pretix
After=docker.service
Requires=docker.service

[Service]
TimeoutStartSec=0
ExecStartPre=-/usr/bin/docker kill %n
ExecStartPre=-/usr/bin/docker rm %n
ExecStart=/usr/bin/docker run --name %n -p 8345:80 \
    -v /var/pretix-data:/data \
    -v /etc/pretix:/etc/pretix \
    -v /var/run/redis:/var/run/redis \
    -v /var/run/mysqld:/var/run/mysqld \
    pretix/standalone:$TAG all
ExecStop=/usr/bin/docker stop %n

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable pretix
systemctl start pretix

# nginx proxy
apt-get -y install nginx
cat << 'EOF' > /etc/nginx/sites-enabled/default
server {
    listen 80 default_server;
    listen [::]:80 ipv6only=on default_server;
    server_name _;

    location / {
        proxy_pass http://localhost:8345/;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto http;
        proxy_set_header Host $http_host;
    }
}
EOF
systemctl reload nginx

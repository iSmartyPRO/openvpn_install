#!/bin/sh
#
# metadata_begin
# recipe: Openvpn
# tags: centos6,centos7,centos8,debian,ubuntu1804,ubuntu1604,ubuntu2004
# revision: 18
# description_ru: Openvpn server. Клиентский ключ доступен в директории /etc/openvpn/easy-rsa/keys
# description_en: Openvpn server. Client key placed in /etc/openvpn/easy-rsa/keys
# metadata_end
#
RNAME=Openvpn

set -x

LOG_PIPE=/tmp/log.pipe.$$                                                                                                                                                                                                                    
mkfifo ${LOG_PIPE}
LOG_FILE=/root/${RNAME}.log
touch ${LOG_FILE}
chmod 600 ${LOG_FILE}

tee < ${LOG_PIPE} ${LOG_FILE} &

exec > ${LOG_PIPE}
exec 2> ${LOG_PIPE}

killjobs() {
    jops="$(jobs -p)"
    test -n "${jops}" && kill ${jops} || :
}
trap killjobs INT TERM EXIT

echo
echo "=== Recipe ${RNAME} started at $(date) ==="
echo

if [ -f /etc/redhat-release ]; then
    OSNAME=centos
else
    OSNAME=debian
fi

Service() {
    # $1 - name
    # $2 - command

    if [ -n "$(which systemctl 2>/dev/null)" ]; then
        systemctl ${2} ${1}.service
    else
        if [ "${2}" = "enable" ]; then
            if [ "${OSNAME}" = "debian" ]; then
                update-rc.d ${1} enable
            else
                chkconfig ${1} on
            fi
        else
            service ${1} ${2}
        fi
    fi
}

NginxRepo() {
    # nginx repo
cat > /etc/yum.repos.d/nginx.repo << EOF
[nginx]
name=nginx repo
baseurl=http://nginx.org/packages/centos/${OSREL}/\$basearch/
gpgcheck=0
enabled=1
EOF
}

if [ "${OSNAME}" = "debian" ]; then
    export DEBIAN_FRONTEND="noninteractive"

	# Wait firstrun script
	while ps uxaww | grep  -v grep | grep -Eq 'apt-get|dpkg' ; do echo "waiting..." ; sleep 3 ; done
    apt-get update
    test -f /usr/bin/which || apt-get -y install which
    which lsb_release 2>/dev/null || apt-get -y install lsb-release
    which logger 2>/dev/null || apt-get -y install bsdutils
    OSREL=$(lsb_release -s -c)
    pkglist="openvpn openssl"
    if [ "${OSREL}" != "wheezy" ]; then
        pkglist="${pkglist} easy-rsa"
        easyrsa_path=/usr/share/easy-rsa
		if [ "x${OSREL}" = "xbuster" ] || [ "x${OSREL}" = "xfocal" ]; then
			easyrsaver=3
		fi
    else
        easyrsa_path=/usr/share/doc/openvpn/examples/easy-rsa/2.0
        oldersa=yes
    fi
    if [ "x${OSREL}" = "xxenial" ]; then
        pkglist="${pkglist} iptables"
    fi
    # Installing packages
    apt-get -y install ${pkglist}
    if [ "x${OSREL}" = "xxenial" ] || [ "x${OSREL}" = "xjessie" ] || [ "x${OSREL}" = "xfocal" ]; then
        vpnservice=openvpn@server
    else
        vpnservice=openvpn
    fi
else
    OSREL=$(printf '%.0f' $(rpm -qf --qf '%{version}' /etc/redhat-release))
    if [ "x${OSREL}" = "x8" ]; then
        PM=dnf
    else
        PM=yum
    fi
    ${PM} -y install epel-release || ${PM} -y install epel-release || ${PM} -y install epel-release
    

    # Setting proxy
    if [ ! "($HTTPPROXYv4)" = "()" ]; then
        # Стрипаем пробелы, если они есть
        PR="($HTTPPROXYv4)"
        PR=$(echo ${PR} | sed "s/''//g" | sed 's/""//g')
        if [ -n "${PR}" ]; then
            echo "proxy=${PR}" >> /etc/yum.conf
        fi
    fi
    
    pkglist="openvpn easy-rsa openssl which policycoreutils"
    if [ "x${OSREL}" = "x7" ]; then
        pkglist="${pkglist} iptables-services"
        vpnservice=openvpn@server
    elif [ "x${OSREL}" = "x8" ]; then
        pkglist="${pkglist} iptables-services"
        vpnservice=openvpn-server@server
    else
        vpnservice=openvpn
    fi

    ${PM} -y install ${pkglist} || ${PM} -y install ${pkglist} || ${PM} -y install ${pkglist}

    # Removing proxy
    sed -r -i "/proxy=/d" /etc/yum.conf

    if [ -e /usr/share/easy-rsa/2.0 ]; then
        easyrsa_path=/usr/share/easy-rsa/2.0
    elif [ -e /usr/share/easy-rsa/3 ]; then
        easyrsa_path=/usr/share/easy-rsa/3
        easyrsaver=3
    fi
fi

cd /etc/openvpn || return
cp -aL ${easyrsa_path} easy-rsa

if [ "${easyrsaver}" != "3" ]; then
    cd easy-rsa
    if [ "x${OSREL}" = "xbuster" ]; then
        cp openssl-easyrsa.cnf openssl.cnf
    fi
    if [ "x${OSREL}" = "xstretch" ] || [ "x${OSREL}" = "xbionic" ] ; then
        cp openssl-1.0.0.cnf openssl.cnf
        sed -i '/subjectAltName/s/^/#/' openssl.cnf
        dd if=/dev/urandom of=/root/.rnd bs=256 count=1
    fi
    . ./vars
    ./clean-all
    # CA
    "$EASY_RSA/pkitool" --batch --initca
    CAPATH=keys/ca.crt
    # server key
    "$EASY_RSA/pkitool" --batch --server server
    SERVERKEYPATH=keys/server.key
    SERVERCRTPATH=keys/server.crt
    # dh
    $OPENSSL dhparam -out ${KEY_DIR}/dh${KEY_SIZE}.pem ${KEY_SIZE}
    # client1
    export KEY_NAME=client1
    if [ -n "${oldersa}" ]; then
        export KEY_CN=client1
    fi
    "$EASY_RSA/pkitool" --batch client1
else
    cd easy-rsa
    if [ "x${OSREL}" = "xbuster" ] || [ "x${OSREL}" = "xfocal" ]; then
        cp vars.example vars
    elif [ "x${OSREL}" = "x8" ]; then
        cp /usr/share/doc/easy-rsa/vars.example vars
    else
        cp /usr/share/doc/easy-rsa-3.0.6/vars.example vars
    fi
    ./easyrsa init-pki
    if [ "x${OSREL}" = "xbuster" ] || [ "x${OSREL}" = "xfocal" ] || [ "x${OSREL}" = "x8" ]; then
        dd if=/dev/urandom of=pki/.rnd bs=256 count=1
    fi
    # CA
    ./easyrsa --batch build-ca nopass
    CAPATH=pki/ca.crt
    # server
    ./easyrsa --req-cn=server --batch gen-req server nopass
    ./easyrsa --req-cn=server --batch sign-req server server
    SERVERKEYPATH=pki/private/server.key
    SERVERCRTPATH=pki/issued/server.crt

    # client1
    ./easyrsa --req-cn=client1 --batch gen-req client1 nopass
    ./easyrsa --req-cn=client1 --batch sign-req client client1

    # dh
    KEY_SIZE=$(awk '$2 ~ /KEY_SIZE/ {print $3}' vars)
    if [ -z "${KEY_SIZE}" ]; then
        KEY_SIZE=2048
    fi
    mkdir -p /etc/openvpn/easy-rsa/keys
    cp pki/private/client1.key /etc/openvpn/easy-rsa/keys
    cp pki/issued/client1.crt /etc/openvpn/easy-rsa/keys
    openssl dhparam -out /etc/openvpn/easy-rsa/keys/dh${KEY_SIZE}.pem ${KEY_SIZE}
fi

if [ "x${OSREL}" = "x8" ]; then
    SERVERCONF=/etc/openvpn/server/server.conf
else
    SERVERCONF=/etc/openvpn/server.conf
fi

cat > ${SERVERCONF} << EOF
port 1194
proto tcp
dev tun
ca /etc/openvpn/easy-rsa/${CAPATH}
cert /etc/openvpn/easy-rsa/${SERVERCRTPATH}
key /etc/openvpn/easy-rsa/${SERVERKEYPATH}  # This file should be kept secret
dh /etc/openvpn/easy-rsa/keys/dh${KEY_SIZE}.pem
server 10.8.0.0 255.255.255.0
ifconfig-pool-persist ipp.txt
keepalive 10 120
comp-lzo
persist-key
persist-tun
verb 3
push "redirect-gateway def1"
push "dhcp-option DNS 8.8.8.8"
EOF

echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p
# Detect default interface name
ifname=$(ip route get 1 | grep -Po '(?<=dev )[^ ]+')
iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o ${ifname} -j MASQUERADE
if [ "${OSNAME}" = "debian" ]; then
    if grep -q exit /etc/rc.local ; then
        sed -i --follow-symlinks "/exit 0/i iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o ${ifname} -j MASQUERADE" /etc/rc.local
    else
        if [ ! -s /etc/rc.local ]; then
            echo "#!/bin/sh" >> /etc/rc.local
        fi
        echo "iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o ${ifname} -j MASQUERADE" >> /etc/rc.local
    fi
    chmod +x /etc/rc.local
else
    if [ "${OSREL}" -ge "7" ]; then
        firewall-cmd --permanent --zone=public --add-port=1194/tcp
        firewall-cmd --permanent --zone=public --add-masquerade
        firewall-cmd --reload
    else
        cat << EOF | iptables-restore
*nat
:PREROUTING ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -s 10.8.0.0/24 -o ${ifname} -j MASQUERADE
COMMIT
*filter
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
-A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
-A INPUT -p icmp -j ACCEPT
-A INPUT -i lo -j ACCEPT
-A INPUT -p tcp -m state --state NEW -m tcp --dport 22 -j ACCEPT
-A INPUT -p tcp -m state --state NEW -m tcp --dport 1194 -j ACCEPT
-A INPUT -j REJECT --reject-with icmp-host-prohibited
COMMIT
EOF
    fi
    service iptables save
fi

if [ "x${OSREL}" = "xxenial" ]; then
    sed -i -r 's/LimitNPROC/#LimitNPROC/' /lib/systemd/system/openvpn@.service
    systemctl daemon-reload
fi

Service ${vpnservice} stop || :
Service ${vpnservice} enable
Service ${vpnservice} start

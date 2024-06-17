#!/bin/bash
apt update
apt install bird git nftables make curl wget wireguard -y

#获取架构类型
architecture=$(uname -m)

#获取信息
echo "请输入对端公网IP"
read dpip

echo "请输入本机内网IP"
read localip

echo "请输入WireGuard本端IP："
read wgip

echo "请输入WireGuard本端端口："
read wgport

echo "请输入WireGuard本端私钥："
read privateKey

echo "请输入WireGuard对端公钥："
read publicKey

#安装udp2raw
if [ "$architecture" == "x86_64" ]; then
    file_url="https://github.com/Hamster-Prime/ospf-wg-udp2raw/releases/download/1.0.0/udp2raw_amd64"
elif [ "$architecture" == "aarch64" ]; then
    file_url="https://github.com/Hamster-Prime/ospf-wg-udp2raw/releases/download/1.0.0/udp2raw_arm"
else
    echo "不支持您的系统架构 目前只支持x86_64与arm64 当前架构为: $architecture"
    exit 1
fi
wget "$file_url" || {
    echo "文件下载失败"
    exit 1
}
for file in udp2raw*; do
    if [ -f "$file" ]; then
        mv "$file" udp2raw
    fi
done
chmod u+x udp2raw
cp udp2raw /usr/local/bin
echo 'net.ipv4.ip_forward = 1' | tee -a /etc/sysctl.conf
tee /etc/systemd/system/udp2raw.service > /dev/null <<EOF
[Unit]
Description=UDP2RAW simple tunnel
Documentation=https://github.com/wangyu-/udp2raw/blob/unified/doc/README.zh-cn.md
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/udp2raw -c -l 0.0.0.0:55535 -r $dpip:55535 --raw-mode faketcp --cipher-mode none -a
Restart=always

[Install]
WantedBy=multi-user.target
EOF

#安装wireguard
tee /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = $wgip/24
ListenPort = $wgport
PrivateKey = $privateKey
Table = off
MTU = 1280

[Peer]
PublicKey = $publicKey
AllowedIPs = 0.0.0.0/0
Endpoint = $localip:55535
EOF

#配置bird服务
mv /etc/bird/bird.conf /etc/bird/bird.conf.orig
mv /etc/bird/bird6.conf /etc/bird/bird6.conf.orig

#IPv4
tee /etc/bird/bird.conf <<EOF
router id $localip;

protocol kernel {
	scan time 60;
	import none;
	export all;
}
 
protocol device {
	scan time 60;
}

protocol static {
    include "routes4.conf";
}

protocol ospf {
    export all;

    area 0.0.0.0 {
        interface "eth0" {
        };
    };
}
EOF

#IPv6
tee /etc/bird/bird6.conf <<EOF
router id $localip;

protocol kernel {
	scan time 60;
	import none;
	export all;
}
 
protocol device {
	scan time 60;
}

protocol static {
    include "routes6.conf";
}

protocol ospf {
    export all;

    area 0.0.0.0 {
        interface "eth0" {
        };
    };
}
EOF

#写入nftables配置文件
mv /etc/nftables.conf /etc/nftables.conf.orig
echo "#!/usr/sbin/nft -f

flush ruleset

table inet filter {
        chain input {
                type filter hook input priority filter; policy accept;
        }

        chain forward {
                type filter hook forward priority filter; policy drop;
                tcp flags & (syn | rst) == syn tcp option maxseg size set rt mtu
                ct state { established, related } accept
                iif "eth0" oifname "wg0" accept
        }

        chain output {
                type filter hook output priority filter; policy accept;
        }
}
table inet nat {
        chain postrouting {
                type nat hook postrouting priority srcnat; policy accept;
                oifname "wg0" masquerade
        }
}" >> /etc/nftables.conf

#重启nftables
nft -f /etc/nftables.conf
systemctl enable nftables

#配置OSPF服务
git clone https://github.com/dndx/nchnroutes.git
mv /root/nchnroutes/Makefile /root/nchnroutes/Makefile.orig
tee /root/nchnroutes/Makefile <<EOF
produce:
	git pull
	curl -o delegated-apnic-latest https://ftp.apnic.net/stats/apnic/delegated-apnic-latest
	curl -o china_ip_list.txt https://raw.githubusercontent.com/17mon/china_ip_list/master/china_ip_list.txt
	python3 produce.py --exclude $dpip/32
	mv routes4.conf /etc/bird/routes4.conf
	mv routes6.conf /etc/bird/routes6.conf
	birdc c
	birdc6 c
EOF
make -C /root/nchnroutes

#启动服务
wg-quick up wg0
systemctl start udp2raw.service

#开机自启
systemctl enable wg-quick@wg0
systemctl enable udp2raw.service

#完成安装
echo "安装完成"
echo "请执行 crontab -e 并在末尾添加 0 0 * * 0 make -C /root/nchnroutes"

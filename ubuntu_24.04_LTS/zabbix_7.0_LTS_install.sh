#!/bin/bash
# Zabbix 7.0 LTS 一键自动化安装脚本
# 适配：Ubuntu 24.04 | MySQL 8.4.8 | Nginx 二进制编译 | Zabbix 7.0 LTS
# 集成：MySQL自动安装 + Nginx二进制安装 + Zabbix完整部署
set -e

# ====================== 自定义配置项（可修改） ======================
# MySQL 配置（与之前安装脚本保持一致）
MYSQL_ROOT_PWD="mysql123"
ZABBIX_DB_NAME="zabbix"
ZABBIX_DB_USER="zabbix"
ZABBIX_DB_PWD="zabbix123"

# Nginx 二进制配置
NGINX_VERSION="1.26.3"
NGINX_INSTALL_DIR="/usr/local/nginx"
NGINX_PORT=80

# Zabbix 配置
ZBX_VERSION="7.0"
SYSTEM_RELEASE="noble" # Ubuntu 24.04 代号

# ====================== 基础检查 ======================
# 检查 root 权限
if [ "$(id -u)" -ne 0 ]; then
    echo "错误：请使用 root 或 sudo 执行脚本！"
    exit 1
fi

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=============================================${NC}"
echo -e "${GREEN}     Zabbix 7.0 LTS 自动化安装脚本           ${NC}"
echo -e "${GREEN}=============================================${NC}"

# ====================== 步骤1：安装系统依赖 ======================
echo -e "${YELLOW}[1/6] 安装系统基础依赖...${NC}"
apt update -y
apt install -y gcc make libpcre3-dev libssl-dev zlib1g-dev \
software-properties-common wget curl lsb-release unzip --no-install-recommends

# ====================== 步骤2：自动化安装 MySQL 8.4.8（完全复用你的脚本） ======================
echo -e "${YELLOW}[2/6] 开始安装 MySQL 8.4.8 数据库...${NC}"
cat > /tmp/mysql_install.sh << 'EOF'
#!/bin/bash
# MySQL 8.4.8 Binary Deployment Script for Ubuntu 24.04 (Final Fixed Version)
# Date: 2026-04-22
set -e # 遇到错误立即退出
# ================= 配置参数 =================
MYSQL_VERSION="8.4.8"
PACKAGE_NAME="mysql-${MYSQL_VERSION}-linux-glibc2.17-x86_64"
TAR_FILE="${PACKAGE_NAME}.tar.xz"
INSTALL_DIR="/usr/local/mysql"
DATA_DIR="/data/mysql"
ROOT_PWD="123456" # 请修改密码
# ================= 1. 环境准备（核心修复） =================
echo "[$(date +%H:%M:%S)] 配置软件源并安装依赖..."
# 1. 启用 universe 仓库（libaio1 位于该仓库）
echo "deb http://archive.ubuntu.com/ubuntu focal main universe" | sudo tee -a /etc/apt/sources.list
# 2. 清理缓存+强制刷新源（解决源同步问题）
sudo apt update
# 3. 安装基础依赖（替换 libtinfo5 为 libtinfo6，Ubuntu 24.04 无 libtinfo5）
apt install -y libaio1 libnuma1 libtinfo6 libncurses6 wget dpkg --no-install-recommends
# 4. 修复 libtinfo5 + libncurses.so.5 依赖（Ubuntu 24.04 仅保留 v6 版本）
LIB_PATH="/lib/x86_64-linux-gnu"
# 修复 libtinfo.so.5
if [ -f "${LIB_PATH}/libtinfo.so.6" ] && [ ! -f "${LIB_PATH}/libtinfo.so.5" ]; then
    ln -sf "${LIB_PATH}/libtinfo.so.6" "${LIB_PATH}/libtinfo.so.5"
    echo "[$(date +%H:%M:%S)] 已创建 libtinfo.so.5 兼容软链接"
fi
# 修复 libncurses.so.5（指向宽字符版 libncursesw.so.6，兼容 MySQL）
if [ -f "${LIB_PATH}/libncursesw.so.6" ] && [ ! -f "${LIB_PATH}/libncurses.so.5" ]; then
    ln -sf "${LIB_PATH}/libncursesw.so.6" "${LIB_PATH}/libncurses.so.5"
    echo "[$(date +%H:%M:%S)] 已创建 libncurses.so.5 兼容软链接"
fi
# ================= 2. 用户与目录准备 =================
if ! id mysql &>/dev/null; then
    groupadd mysql
    useradd -r -g mysql -s /bin/false mysql
fi
# 创建数据目录
mkdir -p ${DATA_DIR}
# ================= 3. 下载与解压 =================
if [ ! -f "/opt/${TAR_FILE}" ]; then
    echo "[$(date +%H:%M:%S)] 正在下载 MySQL 8.4.8..."
    wget https://dev.mysql.com/get/Downloads/MySQL-8.0/${TAR_FILE} -P /opt/ || {
        echo "下载失败，请检查网络或手动下载 ${TAR_FILE} 到 /opt 目录"
        exit 1
    }
fi
echo "[$(date +%H:%M:%S)] 解压安装包..."
cd /opt
tar -xf ${TAR_FILE}
# 关键修复：先删除旧目录再移动，解决 "Directory not empty" 错误
if [ -d "${INSTALL_DIR}" ]; then
    echo "[$(date +%H:%M:%S)] 检测到旧目录，正在清理..."
    rm -rf ${INSTALL_DIR}
fi
# 直接移动重命名，比移动内容更稳健
mv ${PACKAGE_NAME} ${INSTALL_DIR}
# ================= 4. 权限配置 =================
chown -R mysql:mysql ${INSTALL_DIR}
chown -R mysql:mysql ${DATA_DIR}
# ================= 5. 配置文件生成 =================
echo "[$(date +%H:%M:%S)] 生成配置文件..."
# 关键修复：确保 EOF 顶格写，无空格
cat > /etc/my.cnf <<EOF
[mysqld]
user = mysql
basedir = ${INSTALL_DIR}
datadir = ${DATA_DIR}
port = 3306
socket = /tmp/mysql.sock
character-set-server = utf8mb4
collation-server = utf8mb4_general_ci
log-error = ${DATA_DIR}/mysql.err
pid-file = ${DATA_DIR}/mysql.pid
skip-name-resolve
EOF
# ================= 6. 数据库初始化 =================
echo "[$(date +%H:%M:%S)] 初始化数据库 (请稍候)..."
${INSTALL_DIR}/bin/mysqld --initialize --user=mysql --basedir=${INSTALL_DIR} --datadir=${DATA_DIR}
# 检查初始化是否成功
if [ $? -ne 0 ]; then
    echo "错误: 初始化失败，请检查依赖包是否安装完整！"
    exit 1
fi
# ================= 7. 启动服务 =================
echo "[$(date +%H:%M:%S)] 配置并启动服务..."
cp ${INSTALL_DIR}/support-files/mysql.server /etc/init.d/mysql.server
ln -sf ${INSTALL_DIR}/bin/mysql /usr/bin/mysql
# 启动服务
/etc/init.d/mysql.server start
# 等待服务就绪
sleep 3
# ================= 8. 密码修改 =================
if [ -f "${DATA_DIR}/mysql.err" ]; then
    TEMP_PWD=$(grep 'temporary password' ${DATA_DIR}/mysql.err | awk '{print $NF}')
    if [ -n "${TEMP_PWD}" ]; then
        echo "[$(date +%H:%M:%S)] 正在修改 root 密码..."
        ${INSTALL_DIR}/bin/mysql -uroot -p"${TEMP_PWD}" --connect-expired-password -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${ROOT_PWD}'; FLUSH PRIVILEGES;"
        echo "[$(date +%H:%M:%S)] 部署成功！密码: ${ROOT_PWD}"
    else
        echo "警告: 未找到临时密码，可能密码为空或已设置。"
    fi
else
    echo "错误: 日志文件不存在，初始化可能失败。"
fi
EOF

# 执行 MySQL 安装脚本
chmod +x /tmp/mysql_install.sh
bash /tmp/mysql_install.sh
echo -e "${GREEN}MySQL 8.4.8 安装完成！${NC}"

# ====================== 步骤3：二进制编译安装 Nginx ======================
echo -e "${YELLOW}[3/6] 二进制安装 Nginx ${NGINX_VERSION}...${NC}"
cd /opt
wget http://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz
tar -zxvf nginx-${NGINX_VERSION}.tar.gz
cd nginx-${NGINX_VERSION}

# 编译配置
./configure \
--prefix=${NGINX_INSTALL_DIR} \
--with-http_ssl_module \
--with-http_stub_status_module

# 编译安装
make -j$(nproc)
make install

# 创建 Nginx systemd 服务
cat > /etc/systemd/system/nginx.service << EOF
[Unit]
Description=Nginx Web Server
After=network.target

[Service]
Type=forking
ExecStart=${NGINX_INSTALL_DIR}/sbin/nginx
ExecReload=${NGINX_INSTALL_DIR}/sbin/nginx -s reload
ExecStop=${NGINX_INSTALL_DIR}/sbin/nginx -s stop
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

# 启动 Nginx
systemctl daemon-reload
systemctl start nginx
systemctl enable nginx

echo -e "${GREEN}Nginx 二进制安装完成！${NC}"

# ====================== 步骤4：安装 Zabbix 7.0 LTS 源 ======================
echo -e "${YELLOW}[4/6] 配置 Zabbix ${ZBX_VERSION} LTS 官方源...${NC}"
wget https://repo.zabbix.com/zabbix/${ZBX_VERSION}/ubuntu/pool/main/z/zabbix-release/zabbix-release_${ZBX_VERSION}-2+ubuntu${SYSTEM_RELEASE}_all.deb
dpkg -i zabbix-release_${ZBX_VERSION}-2+ubuntu${SYSTEM_RELEASE}_all.deb
apt update -y

# 安装 Zabbix 组件
echo -e "${YELLOW}安装 Zabbix Server、Web、Agent...${NC}"
apt install -y zabbix-server-mysql zabbix-web-mysql zabbix-agent

# ====================== 步骤5：创建 Zabbix 数据库 ======================
echo -e "${YELLOW}[5/6] 初始化 Zabbix 数据库...${NC}"
mysql -uroot -p${MYSQL_ROOT_PWD} -e "CREATE DATABASE ${ZABBIX_DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;"
mysql -uroot -p${MYSQL_ROOT_PWD} -e "CREATE USER '${ZABBIX_DB_USER}'@'localhost' IDENTIFIED BY '${ZABBIX_DB_PWD}';"
mysql -uroot -p${MYSQL_ROOT_PWD} -e "GRANT ALL PRIVILEGES ON ${ZABBIX_DB_NAME}.* TO '${ZABBIX_DB_USER}'@'localhost';"
mysql -uroot -p${MYSQL_ROOT_PWD} -e "FLUSH PRIVILEGES;"

# 导入 Zabbix 初始数据
zcat /usr/share/zabbix-sql-scripts/mysql/server.sql.gz | mysql -u${ZABBIX_DB_USER} -p${ZABBIX_DB_PWD} ${ZABBIX_DB_NAME}

# ====================== 步骤6：配置 Zabbix Server ======================
echo -e "${YELLOW}[6/6] 配置 Zabbix 与 Nginx...${NC}"
# 配置数据库密码
sed -i "s/# DBPassword=/DBPassword=${ZABBIX_DB_PWD}/" /etc/zabbix/zabbix_server.conf

# 配置 Nginx 虚拟主机（Zabbix Web）
cat > ${NGINX_INSTALL_DIR}/conf/conf.d/zabbix.conf << EOF
server {
    listen ${NGINX_PORT};
    server_name localhost;
    root /usr/share/zabbix;
    index index.php index.html;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php$ {
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_buffers 16 16k;
        fastcgi_buffer_size 32k;
    }

    access_log /var/log/nginx/zabbix_access.log;
    error_log /var/log/nginx/zabbix_error.log;
}
EOF

# 启用 Nginx 配置
sed -i 's/# include conf.d\/\*.conf;/include conf.d\/\*.conf;/' ${NGINX_INSTALL_DIR}/conf/nginx.conf

# 安装 PHP 8.3（Ubuntu 24.04 默认）
apt install -y php8.3-fpm php8.3-mysql php8.3-cli php8.3-common

# 重启所有服务
systemctl restart php8.3-fpm
systemctl restart nginx
systemctl restart zabbix-server zabbix-agent
systemctl enable zabbix-server zabbix-agent

# 防火墙放行 80 端口
ufw allow 80/tcp || true

# ====================== 安装完成 ======================
echo -e "${GREEN}=============================================${NC}"
echo -e "${GREEN}       Zabbix 7.0 LTS 安装完成！             ${NC}"
echo -e "${GREEN}=============================================${NC}"
echo -e "访问地址：http://$(hostname -I | awk '{print $1}')"
echo -e "默认账号：Admin"
echo -e "默认密码：zabbix"
echo -e "数据库信息："
echo -e "  Zabbix库名：${ZABBIX_DB_NAME}"
echo -e "  Zabbix用户：${ZABBIX_DB_USER}"
echo -e "  Zabbix密码：${ZABBIX_DB_PWD}"
echo -e "MySQL root 密码：${MYSQL_ROOT_PWD}"
echo -e "${GREEN}=============================================${NC}"
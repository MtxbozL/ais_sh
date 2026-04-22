#!/bin/bash
# Zabbix 7.0 LTS 一键自动化安装脚本（最终修复版）
# 适配：Ubuntu 24.04 | MySQL 8.4.8 | Nginx 二进制编译 | Zabbix 7.0 LTS
set -e

# ====================== 自定义配置项（可修改） ======================
# MySQL 配置（统一密码，只需修改此处）
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
SYSTEM_RELEASE="noble"

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
echo -e "${GREEN}     Zabbix 7.0 LTS 自动化安装脚本（修复版）  ${NC}"
echo -e "${GREEN}=============================================${NC}"

# ====================== 步骤1：安装系统依赖 ======================
echo -e "${YELLOW}[1/6] 安装系统基础依赖...${NC}"
apt update -y
# 新增psmisc（fuser依赖），全量加-y避免交互
apt install -y gcc make libpcre3-dev libssl-dev zlib1g-dev \
software-properties-common wget curl lsb-release unzip psmisc --no-install-recommends

# ====================== 步骤2：自动化安装 MySQL 8.4.8 ======================
echo -e "${YELLOW}[2/6] 开始安装 MySQL 8.4.8 数据库...${NC}"
cat > /tmp/mysql_install.sh << EOF
#!/bin/bash
set -e
# ================= 配置参数（引用外层变量，统一密码） =================
MYSQL_VERSION="8.4.8"
PACKAGE_NAME="mysql-\${MYSQL_VERSION}-linux-glibc2.17-x86_64"
TAR_FILE="\${PACKAGE_NAME}.tar.xz"
INSTALL_DIR="/usr/local/mysql"
DATA_DIR="/data/mysql"
ROOT_PWD="${MYSQL_ROOT_PWD}"

# ================= 1. 环境准备（移除focal源，修复依赖） =================
echo "[$(date +%H:%M:%S)] 安装依赖..."
echo "deb http://archive.ubuntu.com/ubuntu focal main universe" | sudo tee -a /etc/apt/sources.list
apt update -y
# Ubuntu 24.04 原生依赖，无需添加旧版本源
apt install -y libaio1 libnuma1 libtinfo6 libncurses6 wget dpkg --no-install-recommends

# 修复兼容软链接
LIB_PATH="/lib/x86_64-linux-gnu"
if [ -f "\${LIB_PATH}/libtinfo.so.6" ] && [ ! -f "\${LIB_PATH}/libtinfo.so.5" ]; then
    ln -sf "\${LIB_PATH}/libtinfo.so.6" "\${LIB_PATH}/libtinfo.so.5"
    echo "[$(date +%H:%M:%S)] 已创建 libtinfo.so.5 兼容软链接"
fi
if [ -f "\${LIB_PATH}/libncursesw.so.6" ] && [ ! -f "\${LIB_PATH}/libncurses.so.5" ]; then
    ln -sf "\${LIB_PATH}/libncursesw.so.6" "\${LIB_PATH}/libncurses.so.5"
    echo "[$(date +%H:%M:%S)] 已创建 libncurses.so.5 兼容软链接"
fi

# ================= 2. 用户与目录准备 =================
if ! id mysql &>/dev/null; then
    groupadd mysql
    useradd -r -g mysql -s /bin/false mysql
fi
mkdir -p \${DATA_DIR}
# 创建标准Socket目录
mkdir -p /var/run/mysqld
chown mysql:mysql /var/run/mysqld

# ================= 3. 下载与解压 =================
if [ ! -f "/opt/\${TAR_FILE}" ]; then
    echo "[$(date +%H:%M:%S)] 正在下载 MySQL 8.4.8..."
    wget https://dev.mysql.com/get/Downloads/MySQL-8.4/\${TAR_FILE} -P /opt/ || {
        echo "下载失败，请检查网络或手动下载 \${TAR_FILE} 到 /opt 目录"
        exit 1
    }
fi
echo "[$(date +%H:%M:%S)] 解压安装包..."
cd /opt
tar -xf \${TAR_FILE}
if [ -d "\${INSTALL_DIR}" ]; then
    echo "[$(date +%H:%M:%S)] 检测到旧目录，正在清理..."
    rm -rf \${INSTALL_DIR}
fi
mv \${PACKAGE_NAME} \${INSTALL_DIR}

# ================= 4. 权限配置 =================
chown -R mysql:mysql \${INSTALL_DIR}
chown -R mysql:mysql \${DATA_DIR}

# ================= 5. 配置文件生成（统一Socket路径） =================
echo "[$(date +%H:%M:%S)] 生成配置文件..."
cat > /etc/my.cnf <<EOF_a
[mysqld]
user = mysql
basedir = \${INSTALL_DIR}
datadir = \${DATA_DIR}
port = 3306
socket = /var/run/mysqld/mysqld.sock
character-set-server = utf8mb4
collation-server = utf8mb4_general_ci
log-error = \${DATA_DIR}/mysql.err
pid-file = \${DATA_DIR}/mysql.pid
skip-name-resolve
log_bin_trust_function_creators = 1

[client]
socket = /var/run/mysqld/mysqld.sock
EOF_a

# ================= 6. 数据库初始化 =================
echo "[$(date +%H:%M:%S)] 初始化数据库 (请稍候)..."
\${INSTALL_DIR}/bin/mysqld --initialize --user=mysql --basedir=\${INSTALL_DIR} --datadir=\${DATA_DIR}
if [ \$? -ne 0 ]; then
    echo "错误: 初始化失败，请检查依赖包是否安装完整！"
    exit 1
fi

# ================= 7. 启动服务 =================
echo "[$(date +%H:%M:%S)] 配置并启动服务..."
cp \${INSTALL_DIR}/support-files/mysql.server /etc/init.d/mysql.server
ln -sf \${INSTALL_DIR}/bin/mysql /usr/bin/mysql
/etc/init.d/mysql.server start
sleep 3

# ================= 8. 密码修改 =================
if [ -f "\${DATA_DIR}/mysql.err" ]; then
    TEMP_PWD=\$(grep 'temporary password' \${DATA_DIR}/mysql.err | awk '{print \$NF}')
    if [ -n "\${TEMP_PWD}" ]; then
        echo "[$(date +%H:%M:%S)] 正在修改 root 密码..."
        \${INSTALL_DIR}/bin/mysql -uroot -p"\${TEMP_PWD}" --connect-expired-password -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '\${ROOT_PWD}'; FLUSH PRIVILEGES;"
        echo "[$(date +%H:%M:%S)] MySQL 部署成功！root密码: \${ROOT_PWD}"
    else
        echo "警告: 未找到临时密码，可能密码为空或已设置。"
    fi
else
    echo "错误: 日志文件不存在，初始化可能失败。"
    exit 1
fi
EOF

# 执行 MySQL 安装脚本
chmod +x /tmp/mysql_install.sh
bash /tmp/mysql_install.sh
echo -e "${GREEN}MySQL 8.4.8 安装完成！${NC}"

# ====================== 步骤3：二进制编译安装 Nginx ======================
echo -e "${YELLOW}[3/6] 二进制安装 Nginx ${NGINX_VERSION}...${NC}"
cd /opt
if [ ! -f "nginx-${NGINX_VERSION}.tar.gz" ]; then
    wget http://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz
fi
tar -zxvf nginx-${NGINX_VERSION}.tar.gz
cd nginx-${NGINX_VERSION}

# 编译配置（显式指定pid路径，与systemd匹配）
./configure \
--prefix=${NGINX_INSTALL_DIR} \
--pid-path=${NGINX_INSTALL_DIR}/logs/nginx.pid \
--with-http_ssl_module \
--with-http_stub_status_module

# 编译安装
make -j$(nproc)
make install

# ===== 修复后的 Nginx systemd 服务文件 =====
cat > /etc/systemd/system/nginx.service << EOF
[Unit]
Description=Nginx Web Server
After=network.target
Documentation=man:nginx(8)
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=forking
PIDFile=${NGINX_INSTALL_DIR}/logs/nginx.pid
ExecStart=${NGINX_INSTALL_DIR}/sbin/nginx -c ${NGINX_INSTALL_DIR}/conf/nginx.conf
ExecReload=${NGINX_INSTALL_DIR}/sbin/nginx -s reload
ExecStop=${NGINX_INSTALL_DIR}/sbin/nginx -s stop
ExecStopPost=/bin/rm -f ${NGINX_INSTALL_DIR}/logs/nginx.pid
PrivateTmp=true
TimeoutStartSec=30
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

# 预创建目录并修复权限
mkdir -p ${NGINX_INSTALL_DIR}/conf/conf.d
mkdir -p /var/log/nginx
mkdir -p ${NGINX_INSTALL_DIR}/logs
chown -R root:root ${NGINX_INSTALL_DIR}

# 验证Nginx配置（关键：启动前检查配置是否合法）
echo -e "${YELLOW}验证 Nginx 配置文件...${NC}"
${NGINX_INSTALL_DIR}/sbin/nginx -t
if [ $? -ne 0 ]; then
    echo -e "${RED}Nginx 配置错误，请检查编译/配置步骤！${NC}"
    exit 1
fi

# 启动 Nginx
systemctl daemon-reload
systemctl start nginx
systemctl enable nginx
echo -e "${GREEN}Nginx 二进制安装完成！${NC}"

# ====================== 步骤4：安装 Zabbix 7.0 LTS 源 ======================
echo -e "${YELLOW}[4/6] 配置 Zabbix ${ZBX_VERSION} LTS 官方源...${NC}"
cd /opt
if [ ! -f "zabbix-release_latest_7.0+ubuntu24.04_all.deb" ]; then
    wget https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_7.0+ubuntu24.04_all.deb
fi

# ================= 增强版：dpkg 锁处理逻辑（循环等待+彻底清理） =================
echo -e "${YELLOW}[4/6.1] 检查并释放 dpkg 锁（可能需要几秒钟）...${NC}"
MAX_WAIT=30
WAIT_COUNT=0
LOCK_FILES="/var/lib/dpkg/lock /var/lib/dpkg/lock-frontend"

# 函数：检查是否有进程持有锁
check_lock() {
    for lock in $LOCK_FILES; do
        if fuser $lock >/dev/null 2>&1; then
            return 0 # 锁被占用
        fi
    done
    return 1 # 锁空闲
}

# 循环等待锁释放
while check_lock; do
    if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
        echo -e "${RED}错误：等待 dpkg 锁超时（${MAX_WAIT}秒），请手动清理后重试！${NC}"
        echo -e "提示：运行 'sudo fuser -vki /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend' 查看并杀进程"
        exit 1
    fi
    
    echo -e "${YELLOW}... dpkg 锁被占用，等待中（${WAIT_COUNT}/${MAX_WAIT}）...${NC}"
    
    # 尝试优雅释放锁
    fuser -vk -TERM $LOCK_FILES >/dev/null 2>&1 || true
    
    sleep 2
    WAIT_COUNT=$((WAIT_COUNT + 2))
done

# 锁释放后，再次确保 dpkg 状态正常
echo -e "${GREEN}dpkg 锁已释放，继续安装...${NC}"
dpkg --configure --pending || true

dpkg -i zabbix-release_latest_7.0+ubuntu24.04_all.deb
apt update -y

# 修复：移除-i交互参数，避免卡死
fuser -vk -TERM /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || true
sleep 1
dpkg --configure --pending || true

# 安装 Zabbix 组件，全量加-y
echo -e "${YELLOW}安装 Zabbix Server、Web、Agent2...${NC}"
apt install -y zabbix-server-mysql zabbix-frontend-php zabbix-sql-scripts zabbix-agent2
apt install -y zabbix-agent2-plugin-mongodb zabbix-agent2-plugin-mssql zabbix-agent2-plugin-postgresql

# 兜底清理残留Apache服务，避免80端口冲突
echo -e "${YELLOW}[4/6.2] 清理残留Apache服务...${NC}"
if systemctl list-unit-files | grep -q apache2.service; then
    systemctl stop apache2 2>/dev/null || true
    systemctl disable apache2 2>/dev/null || true
    echo -e "${GREEN}已停止并禁用残留的Apache服务，避免端口冲突${NC}"
fi

# ====================== 步骤5：创建 Zabbix 数据库 ======================
echo -e "${YELLOW}[5/6] 初始化 Zabbix 数据库...${NC}"
# 用统一的root密码连接数据库
mysql -uroot -p${MYSQL_ROOT_PWD} -e "CREATE DATABASE IF NOT EXISTS ${ZABBIX_DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;"
mysql -uroot -p${MYSQL_ROOT_PWD} -e "CREATE USER IF NOT EXISTS '${ZABBIX_DB_USER}'@'localhost' IDENTIFIED BY '${ZABBIX_DB_PWD}';"
mysql -uroot -p${MYSQL_ROOT_PWD} -e "GRANT ALL PRIVILEGES ON ${ZABBIX_DB_NAME}.* TO '${ZABBIX_DB_USER}'@'localhost';"
mysql -uroot -p${MYSQL_ROOT_PWD} -e "FLUSH PRIVILEGES;"

# 导入 Zabbix 初始数据
zcat /usr/share/zabbix-sql-scripts/mysql/server.sql.gz | mysql -u${ZABBIX_DB_USER} -p${ZABBIX_DB_PWD} ${ZABBIX_DB_NAME}

# ====================== 步骤6：配置 Zabbix Server 与 Nginx ======================
echo -e "${YELLOW}[6/6] 配置 Zabbix 与 Nginx...${NC}"
# 配置数据库密码
sed -i "s/# DBPassword=/DBPassword=${ZABBIX_DB_PWD}/" /etc/zabbix/zabbix_server.conf

# 重做 nginx 配置文件
mv ${NGINX_INSTALL_DIR}/conf/nginx.conf ${NGINX_INSTALL_DIR}/conf/nginx.conf.bak

cat > ${NGINX_INSTALL_DIR}/conf/nginx.conf << EOF_A
user www-data;
worker_processes  1;

events {
    worker_connections  1024;
}

http {
    include       mime.types;
    default_type  application/octet-stream;

    sendfile        on;

    keepalive_timeout  65;

    include conf.d/*.conf;
}
EOF_A

# 配置 Nginx 虚拟主机
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

# 启用 Nginx 子配置
sed -i 's/# include conf.d\/\*.conf;/include conf.d\/\*.conf;/' ${NGINX_INSTALL_DIR}/conf/nginx.conf

# 安装 PHP 8.3
apt install -y php8.3-fpm php8.3-mysql php8.3-cli php8.3-common

# 重启所有服务（修复：agent改为agent2）
systemctl restart php8.3-fpm
systemctl restart nginx
systemctl restart zabbix-server zabbix-agent2
systemctl enable zabbix-server zabbix-agent2

# 防火墙放行端口
ufw allow 80/tcp 10050/tcp 10051/tcp || true

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
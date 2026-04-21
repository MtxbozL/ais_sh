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
ROOT_PWD="MyNewPass123!" # 请修改密码
# ================= 1. 环境准备（核心修复） =================
echo "[$(date +%H:%M:%S)] 配置软件源并安装依赖..."
# 1. 启用 universe 仓库（libaio1 位于该仓库）
add-apt-repository universe -y || true
# 2. 清理缓存+强制刷新源（解决源同步问题）
apt clean && apt update --fix-missing -y
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
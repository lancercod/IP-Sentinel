#!/bin/bash

# ==========================================================
# 脚本名称: install_lite.sh (IP-Sentinel 轻量独立部署脚本)
# 核心功能: 纯服务器端 Google 区域纠偏，无需 Telegram，零外部依赖
# 使用场景: 只想在服务器后台静默运行 Google IP 位置纠偏，不需要远程控制
# ==========================================================

# ==========================================================
# 🛑 核心权限防线: 检查是否以 root 权限运行
# ==========================================================
if [ "$EUID" -ne 0 ]; then
  echo -e "\033[31m❌ 权限被拒绝: 部署 IP-Sentinel 需要最高系统权限。\033[0m"
  echo -e "💡 请切换到 root 用户 (执行 su root 或 sudo -i) 后重新运行指令。"
  exit 1
fi

REPO_RAW_URL="https://raw.githubusercontent.com/hotyue/IP-Sentinel/main"
INSTALL_DIR="/opt/ip_sentinel"
CONFIG_FILE="${INSTALL_DIR}/config.conf"

# [核心: 动态提取 Agent 专属版本锚点 (KV 解析法)]
TARGET_VERSION=$(curl -s -m 3 "${REPO_RAW_URL}/version.txt" | grep "^AGENT_VERSION=" | cut -d'=' -f2 | tr -d '[:space:]')
TARGET_VERSION=${TARGET_VERSION:-"3.5.1"}

# 轻量级版本号比对函数
version_lt() {
    test "$(printf '%s\n' "$1" "$2" | sort -V | head -n 1)" = "$1" && test "$1" != "$2"
}

# 生成节点身份哈希 (以公网 IP 为种子)
make_node_name() {
    local safe_ip="${1:-127.0.0.1}"
    local ip_hash
    ip_hash=$(echo "$safe_ip" | md5sum | cut -c 1-4 | tr 'a-z' 'A-Z')
    echo "$(hostname | tr -cd 'a-zA-Z0-9' | cut -c 1-10)-${ip_hash}"
}

# 探测链路类型：原生直连返回 "direct"，NAT 返回 "nat"
detect_nat() {
    local safe_ip="$1"
    local raw_ip
    raw_ip=$(echo "$safe_ip" | tr -d '[]')
    local test_target
    if [[ "$raw_ip" == *":"* ]]; then
        test_target="https://[2606:4700:4700::1111]"
    else
        test_target="https://1.1.1.1"
    fi
    if curl --interface "$raw_ip" -sI -m 3 "$test_target" >/dev/null 2>&1; then
        echo "direct"
    else
        echo "nat"
    fi
}

# 1. 依赖检查与智能安装 (curl, jq, cron)
echo -e "\n[1/6] 正在探测并安装基础环境依赖 (curl, jq, cron)..."

REQUIRED_CMDS=("curl" "jq" "crontab")
MISSING_CMDS=()

for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        MISSING_CMDS+=("$cmd")
    fi
done

if [ ${#MISSING_CMDS[@]} -gt 0 ]; then
    echo "⏳ 发现缺失依赖: ${MISSING_CMDS[*]}，正在尝试自动补齐..."

    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y >/dev/null 2>&1
        apt-get install -y --no-install-recommends curl jq cron >/dev/null 2>&1
        systemctl enable cron >/dev/null 2>&1 && systemctl start cron >/dev/null 2>&1

    elif command -v yum >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1; then
        PKG_MGR="yum"
        OPT_ARGS=""
        if command -v dnf >/dev/null 2>&1; then
            PKG_MGR="dnf"
            OPT_ARGS="--setopt=install_weak_deps=False"
        fi
        $PKG_MGR install -y $OPT_ARGS curl jq cronie >/dev/null 2>&1
        systemctl enable crond >/dev/null 2>&1 && systemctl start crond >/dev/null 2>&1

    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache curl jq dcron bash >/dev/null 2>&1
        mkdir -p /var/spool/cron/crontabs
        rc-update add crond default >/dev/null 2>&1
        service crond start >/dev/null 2>&1

    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm curl jq cronie >/dev/null 2>&1
        systemctl enable cronie >/dev/null 2>&1 && systemctl start cronie >/dev/null 2>&1

    else
        echo -e "\033[31m❌ 自动安装失败：系统未知的包管理器。\033[0m"
        echo -e "\033[33m⚠️ 请根据您的操作系统，手动执行以下安装命令后重新运行本脚本：\033[0m"
        echo -e "  Debian/Ubuntu: \033[36mapt-get update && apt-get install -y --no-install-recommends curl jq cron\033[0m"
        echo -e "  CentOS/RHEL:   \033[36myum install -y curl jq cronie\033[0m"
        echo -e "  Alpine Linux:  \033[36mapk add --no-cache curl jq dcron bash\033[0m"
        echo -e "  Arch Linux:    \033[36mpacman -Sy curl jq cronie\033[0m"
        exit 1
    fi

    for cmd in "${REQUIRED_CMDS[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo -e "\033[31m❌ 致命错误：核心命令 '$cmd' 仍未找到！\033[0m"
            exit 1
        fi
    done
fi
echo -e "\033[32m✅ 基础环境检测通过。\033[0m"

# 2. 交互式地区选择
echo -e "\n[2/6] 正在连线云端，拉取全球节点地图..."
curl -sL "${REPO_RAW_URL}/data/map.json" -o "/tmp/map.json"

if [ ! -s "/tmp/map.json" ]; then
    echo -e "\033[31m❌ 拉取全球地图失败！请检查网络或 GitHub 仓库地址。\033[0m"
    exit 1
fi

# 是否为平滑升级
UPGRADE_MODE="false"
KEEP_LOGS="true"

if [ -f "$CONFIG_FILE" ]; then
    echo -e "\n\033[33m💡 检测到本机已部署过 IP-Sentinel Lite。\033[0m"
    read -p "👉 是否按原配置直接进行平滑升级？(y/n, 默认y): " UPGRADE_CHOICE
    if [[ -z "$UPGRADE_CHOICE" || "$UPGRADE_CHOICE" =~ ^[Yy]$ ]]; then
        UPGRADE_MODE="true"
        read -p "👉 是否保留历史运行日志？(y/n, 默认y): " LOG_CHOICE
        if [[ "$LOG_CHOICE" =~ ^[Nn]$ ]]; then
            KEEP_LOGS="false"
        fi
        source "$CONFIG_FILE"
        echo -e "\033[32m✅ 已激活 [平滑升级模式]，即将跳过基础配置，直接更新核心装甲...\033[0m"
    else
        echo -e "\033[33m🔄 您选择了重新配置，旧的哨兵数据将被彻底抹除。\033[0m"
    fi
fi

# ================== 安装前环境清理 ==================
echo -e "\n⏳ 正在清理旧版守护进程与冗余任务..."

if command -v systemctl >/dev/null 2>&1; then
    systemctl stop ip-sentinel-runner.timer ip-sentinel-updater.timer >/dev/null 2>&1 || true
fi

pkill -9 -f "runner.sh" >/dev/null 2>&1 || true

crontab -l 2>/dev/null | grep -v "ip_sentinel" > /tmp/cron_clean || true
[ -f /tmp/cron_clean ] && crontab /tmp/cron_clean 2>/dev/null
rm -f /tmp/cron_clean

if [ "$UPGRADE_MODE" == "true" ]; then
    rm -rf "${INSTALL_DIR}/core" 2>/dev/null
    if [ "$KEEP_LOGS" == "false" ]; then
        rm -rf "${INSTALL_DIR}/logs" 2>/dev/null
        echo -e "🗑️ 历史日志已按指令清空。"
    else
        echo -e "📦 历史配置与战地日志已妥善保留。"
    fi
else
    if [ -d "$INSTALL_DIR" ]; then
        rm -rf "${INSTALL_DIR}/core" "${INSTALL_DIR}/data" "${INSTALL_DIR}/config.conf" 2>/dev/null
    fi
fi
echo -e "\033[32m✅ 环境清理完毕！\033[0m"

# ====================================================
# 全新安装时，才执行交互式地区配置
# ====================================================
if [ "$UPGRADE_MODE" == "false" ]; then

    # 📍 动态零级菜单：战区(大洲)选择
    echo -e "\n\033[36m📍 【第零级】请选择目标战区 (Continent):\033[0m"
    jq -r '.continents[] | "\(.id)|\(.name)"' /tmp/map.json > /tmp/continents.txt
    i=1; CONT_MAP=()
    while IFS="|" read -r cont_id cont_name; do
        echo "  $i) $cont_name"
        CONT_MAP[$i]="$cont_id"
        ((i++))
    done < /tmp/continents.txt

    read -p "请输入选择 [1-$((i-1))] (默认1): " CONT_SEL
    CONT_SEL=${CONT_SEL:-1}
    CONT_ID="${CONT_MAP[$CONT_SEL]}"

    # 📍 动态一级菜单：国家选择
    echo -e "\n\033[36m📍 【第一级】正在检索 [$CONT_ID] 战区下的国家/地区...\033[0m"
    jq -r ".continents[] | select(.id==\"$CONT_ID\") | .countries[] | \"\(.id)|\(.name)|\(.keyword_file)\"" /tmp/map.json > /tmp/countries.txt
    i=1; COUNTRY_MAP=(); KEYWORD_MAP=()
    while IFS="|" read -r c_id c_name k_file; do
        echo "  $i) $c_name"
        COUNTRY_MAP[$i]="$c_id"
        KEYWORD_MAP[$i]="$k_file"
        ((i++))
    done < /tmp/countries.txt

    read -p "请输入选择 [1-$((i-1))] (默认1): " C_SEL
    C_SEL=${C_SEL:-1}
    COUNTRY_ID="${COUNTRY_MAP[$C_SEL]}"
    KEYWORD_FILE="${KEYWORD_MAP[$C_SEL]}"
    REGION_CODE="$COUNTRY_ID"

    # 📍 动态二级菜单：省/州选择
    echo -e "\n\033[36m📍 【第二级】正在检索 [$COUNTRY_ID] 的行政区数据...\033[0m"
    jq -r ".continents[] | select(.id==\"$CONT_ID\") | .countries[] | select(.id==\"$COUNTRY_ID\") | .states[] | \"\(.id)|\(.name)\"" /tmp/map.json > /tmp/states.txt
    STATE_COUNT=$(wc -l < /tmp/states.txt)

    if [ "$STATE_COUNT" -eq 1 ]; then
        IFS="|" read -r STATE_ID STATE_NAME < /tmp/states.txt
        echo -e "\033[32m💡 该国家下仅有单一配置 [$STATE_NAME]，已自动跃迁。\033[0m"
    else
        i=1; STATE_MAP=()
        while IFS="|" read -r s_id s_name; do
            echo "  $i) $s_name"
            STATE_MAP[$i]="$s_id"
            ((i++))
        done < /tmp/states.txt
        read -p "请输入选择 [1-$((i-1))] (默认1): " S_SEL
        S_SEL=${S_SEL:-1}
        STATE_ID="${STATE_MAP[$S_SEL]}"
    fi

    # 📍 动态三级菜单：城市选择
    echo -e "\n\033[36m📍 【第三级】请锁定具体城市节点:\033[0m"
    jq -r ".continents[] | select(.id==\"$CONT_ID\") | .countries[] | select(.id==\"$COUNTRY_ID\") | .states[] | select(.id==\"$STATE_ID\") | .cities[] | \"\(.id)|\(.name)\"" /tmp/map.json > /tmp/cities.txt
    CITY_COUNT=$(wc -l < /tmp/cities.txt)

    if [ "$CITY_COUNT" -eq 1 ]; then
        IFS="|" read -r CITY_ID CITY_NAME < /tmp/cities.txt
        echo -e "\033[32m💡 该区域下仅有单一城市 [$CITY_NAME]，已自动锁定。\033[0m"
    else
        i=1; CITY_MAP=(); CITY_NAME_MAP=()
        while IFS="|" read -r c_id c_name; do
            echo "  $i) $c_name"
            CITY_MAP[$i]="$c_id"
            CITY_NAME_MAP[$i]="$c_name"
            ((i++))
        done < /tmp/cities.txt
        read -p "请输入选择 [1-$((i-1))] (默认1): " CI_SEL
        CI_SEL=${CI_SEL:-1}
        CITY_ID="${CITY_MAP[$CI_SEL]}"
        CITY_NAME="${CITY_NAME_MAP[$CI_SEL]}"
    fi

    rm -f /tmp/map.json /tmp/continents.txt /tmp/countries.txt /tmp/states.txt /tmp/cities.txt

    mkdir -p "${INSTALL_DIR}/core"
    mkdir -p "${INSTALL_DIR}/data/keywords"
    mkdir -p "${INSTALL_DIR}/data/regions/${COUNTRY_ID}/${STATE_ID}"
    mkdir -p "${INSTALL_DIR}/logs"

    # 3. 网络栈探测与出口 IP 锁定
    echo -e "\n[3/6] 正在探测本机网络栈与可用出口..."

    DETECT_V4=$( (curl -4 -s -m 3 api.ip.sb/ip || curl -4 -s -m 3 ifconfig.me || curl -4 -s -m 3 ipv4.icanhazip.com) 2>/dev/null | grep -E "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | head -n 1 | tr -d '[:space:]')
    DETECT_V6=$( (curl -6 -s -m 3 api.ip.sb/ip || curl -6 -s -m 3 ifconfig.me || curl -6 -s -m 3 ipv6.icanhazip.com) 2>/dev/null | grep -E "^[0-9a-fA-F:]+.*:" | head -n 1 | tr -d '[:space:]')

    IP_OPTIONS=()
    IP_PROTO=()

    [[ -n "$DETECT_V4" ]] && { IP_OPTIONS+=("$DETECT_V4"); IP_PROTO+=("4"); }
    [[ -n "$DETECT_V6" ]] && { IP_OPTIONS+=("$DETECT_V6"); IP_PROTO+=("6"); }

    if [ ${#IP_OPTIONS[@]} -eq 0 ]; then
        echo -e "\033[33m⚠️ 未能自动探测到公网 IP，请手动指定。\033[0m"
        read -p "请输入您要绑定的公网 IP (v4 或 v6): " PUBLIC_IP
        [[ "$PUBLIC_IP" == *":"* ]] && IP_PREF="6" || IP_PREF="4"
    else
        echo "📍 发现可用出口 IP，请选择要注册与养护的锚点:"
        for i in "${!IP_OPTIONS[@]}"; do
            num=$((i+1))
            if [ "${IP_PROTO[$i]}" == "4" ]; then
                echo "  $num) 🌐 IPv4: ${IP_OPTIONS[$i]} (默认选项)"
            else
                echo "  $num) 🌌 IPv6: ${IP_OPTIONS[$i]}"
            fi
        done
        CUSTOM_OPT=$(( ${#IP_OPTIONS[@]} + 1 ))
        echo "  $CUSTOM_OPT) ✍️ 手动指定其他 IP (适合多 IP 站群机)"

        read -p "请输入选择 (默认1): " IP_CHOICE
        IP_CHOICE=${IP_CHOICE:-1}

        if [ "$IP_CHOICE" -le "${#IP_OPTIONS[@]}" ] && [ "$IP_CHOICE" -gt 0 ]; then
            idx=$((IP_CHOICE-1))
            PUBLIC_IP="${IP_OPTIONS[$idx]}"
            IP_PREF="${IP_PROTO[$idx]}"
        elif [ "$IP_CHOICE" -eq "$CUSTOM_OPT" ]; then
            read -p "请输入您要绑定的公网 IP (v4 或 v6): " PUBLIC_IP
            [[ "$PUBLIC_IP" == *":"* ]] && IP_PREF="6" || IP_PREF="4"
        else
            PUBLIC_IP="${IP_OPTIONS[0]}"
            IP_PREF="${IP_PROTO[0]}"
        fi
    fi

    # IPv6 方括号护甲
    if [[ "$PUBLIC_IP" == *":"* ]] && [[ "$PUBLIC_IP" != *"["* ]]; then
        SAFE_PUBLIC_IP="[${PUBLIC_IP}]"
    else
        SAFE_PUBLIC_IP="$PUBLIC_IP"
    fi

    # NAT 环境嗅探
    echo -n "🕵️ 正在进行出站链路试射 (NAT环境与双栈嗅探)..."
    NAT_TYPE=$(detect_nat "$SAFE_PUBLIC_IP")
    if [ "$NAT_TYPE" == "direct" ]; then
        echo -e " \033[32m✅ 原生直连，物理网卡死锁已激活。\033[0m"
        BIND_IP="$SAFE_PUBLIC_IP"
    else
        echo -e " \033[33m⚠️ 发现 NAT/虚拟路由架构，自动卸除网卡枷锁，交由内核路由。\033[0m"
        BIND_IP=""
    fi
    echo -e "\033[32m✅ 哨兵对外联络点已永久锁定至: $SAFE_PUBLIC_IP\033[0m"

    # 节点身份生成
    NODE_NAME=$(make_node_name "$SAFE_PUBLIC_IP")

    # 4. 拉取区域规则
    echo -e "\n[4/6] 正在从云端数据仓库拉取 [${CITY_NAME}] 节点的底层规则..."
    REGION_JSON_FILE="${INSTALL_DIR}/data/regions/${COUNTRY_ID}/${STATE_ID}/${CITY_ID}.json"
    curl -sL "${REPO_RAW_URL}/data/regions/${COUNTRY_ID}/${STATE_ID}/${CITY_ID}.json" -o "$REGION_JSON_FILE"

    if [ ! -s "$REGION_JSON_FILE" ]; then
        echo "❌ 拉取区域规则失败！请检查网络或 GitHub 仓库地址。"
        exit 1
    fi

    REGION_NAME=$(jq -r '.region_name' "$REGION_JSON_FILE")
    BASE_LAT=$(jq -r '.google_module.base_lat' "$REGION_JSON_FILE")
    BASE_LON=$(jq -r '.google_module.base_lon' "$REGION_JSON_FILE")
    LANG_PARAMS=$(jq -r '.google_module.lang_params' "$REGION_JSON_FILE")
    VALID_URL_SUFFIX=$(jq -r '.google_module.valid_url_suffix' "$REGION_JSON_FILE")

    # 写入配置文件 (无 Telegram 字段)
    cat > "$CONFIG_FILE" << EOF
# IP-Sentinel Lite 本地固化配置 (生成时间: $(date '+%Y-%m-%d %H:%M:%S'))
AGENT_VERSION="$TARGET_VERSION"
REGION_CODE="$REGION_CODE"
REGION_NAME="$REGION_NAME"
BASE_LAT="$BASE_LAT"
BASE_LON="$BASE_LON"
LANG_PARAMS="$LANG_PARAMS"
VALID_URL_SUFFIX="$VALID_URL_SUFFIX"

# 模块开关 (Lite 模式仅启用 Google 区域纠偏)
ENABLE_GOOGLE="true"
ENABLE_TRUST="false"

# Telegram 联控 (Lite 模式不使用)
TG_TOKEN=""
TG_API_URL=""
CHAT_ID=""

INSTALL_DIR="$INSTALL_DIR"
LOG_FILE="${INSTALL_DIR}/logs/sentinel.log"

# 网络出口配置
IP_PREF="$IP_PREF"
PUBLIC_IP="$SAFE_PUBLIC_IP"
BIND_IP="$BIND_IP"

# 节点身份
NODE_NAME="$NODE_NAME"
NODE_ALIAS="$NODE_NAME"

# OTA (Lite 模式不使用远程升级)
ENABLE_OTA="false"
EOF

    chmod 600 "$CONFIG_FILE"

fi
# 🛑 全新安装配置块结束

# ====================================================
# 升级模式：老节点配置无损热迁移
# ====================================================
if [ "$UPGRADE_MODE" == "true" ]; then
    if ! grep -q "PUBLIC_IP=" "$CONFIG_FILE"; then
        echo -e "\n🔄 [平滑迁移] 正在对老节点进行双核身份架构升级..."

        MIGRATE_IP=$(curl -${IP_PREF:-4} -s -m 5 api.ip.sb/ip | tr -d '[:space:]')
        [[ "$MIGRATE_IP" == *":"* ]] && [[ "$MIGRATE_IP" != *"["* ]] && MIGRATE_IP="[${MIGRATE_IP}]"

        echo -n "🕵️ 正在进行补发链路试射..."
        NAT_TYPE=$(detect_nat "$MIGRATE_IP")
        if [ "$NAT_TYPE" == "direct" ]; then
            echo -e " \033[32m✅ 原生直连，网卡死锁已继承。\033[0m"
            NEW_BIND_IP="$MIGRATE_IP"
        else
            echo -e " \033[33m⚠️ 发现 NAT 架构，已自动卸除老版本的物理枷锁。\033[0m"
            NEW_BIND_IP=""
        fi

        sed -i "s/^BIND_IP=.*/BIND_IP=\"$NEW_BIND_IP\"/" "$CONFIG_FILE"
        echo "PUBLIC_IP=\"$MIGRATE_IP\"" >> "$CONFIG_FILE"
        SAFE_PUBLIC_IP="$MIGRATE_IP"
        BIND_IP="$NEW_BIND_IP"
    else
        SAFE_PUBLIC_IP=$(grep "^PUBLIC_IP=" "$CONFIG_FILE" | cut -d'"' -f2)
    fi

    if ! grep -q "^NODE_NAME=" "$CONFIG_FILE"; then
        NODE_NAME=$(make_node_name "${SAFE_PUBLIC_IP:-127.0.0.1}")
        echo "NODE_NAME=\"$NODE_NAME\"" >> "$CONFIG_FILE"
        echo "NODE_ALIAS=\"$NODE_NAME\"" >> "$CONFIG_FILE"
    fi

    if grep -q "^AGENT_VERSION=" "$CONFIG_FILE"; then
        sed -i "s/^AGENT_VERSION=.*/AGENT_VERSION=\"$TARGET_VERSION\"/" "$CONFIG_FILE"
    else
        echo "AGENT_VERSION=\"$TARGET_VERSION\"" >> "$CONFIG_FILE"
    fi

    # 确保 Lite 模式下 ENABLE_TRUST 始终为 false
    if grep -q "^ENABLE_TRUST=" "$CONFIG_FILE"; then
        sed -i "s/^ENABLE_TRUST=.*/ENABLE_TRUST=\"false\"/" "$CONFIG_FILE"
    fi
fi

# 5. 拉取核心组件 (仅 Google 纠偏所需，不含 Telegram 相关模块)
echo -e "\n[5/6] 正在部署核心引擎与热数据..."
mkdir -p "${INSTALL_DIR}/core"
mkdir -p "${INSTALL_DIR}/data/keywords"

curl -sL "${REPO_RAW_URL}/core/runner.sh"   -o "${INSTALL_DIR}/core/runner.sh"
curl -sL "${REPO_RAW_URL}/core/updater.sh"  -o "${INSTALL_DIR}/core/updater.sh"
curl -sL "${REPO_RAW_URL}/core/mod_google.sh" -o "${INSTALL_DIR}/core/mod_google.sh"
curl -sL "${REPO_RAW_URL}/core/uninstall.sh"  -o "${INSTALL_DIR}/core/uninstall.sh"
curl -sL "${REPO_RAW_URL}/data/user_agents.txt" -o "${INSTALL_DIR}/data/user_agents.txt"

if [ "$UPGRADE_MODE" == "false" ]; then
    curl -sL "${REPO_RAW_URL}/data/keywords/${KEYWORD_FILE}" -o "${INSTALL_DIR}/data/keywords/${KEYWORD_FILE}"
else
    REGION_CODE_CFG=$(grep "^REGION_CODE=" "$CONFIG_FILE" | cut -d'"' -f2)
    curl -sL "${REPO_RAW_URL}/data/keywords/kw_${REGION_CODE_CFG}.txt" -o "${INSTALL_DIR}/data/keywords/kw_${REGION_CODE_CFG}.txt" 2>/dev/null || true
fi

chmod +x "${INSTALL_DIR}/core/"*.sh

# UA 指纹库更新时间戳
echo $(date +%s) > "${INSTALL_DIR}/core/.ua_last_update"

# 6. 配置系统定时任务 (纯服务器端，无 Telegram 守护进程)
echo -e "\n[6/6] 正在注入系统调度器..."

if command -v systemctl >/dev/null 2>&1; then
    echo "💡 检测到 Systemd 环境，正在部署原生守护服务..."

    # Runner 核心养护模块服务与定时器
    cat > /etc/systemd/system/ip-sentinel-runner.service << EOF
[Unit]
Description=IP-Sentinel Runner Service
After=network.target
[Service]
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
SyslogIdentifier=ip-sentinel
Type=oneshot
ExecStart=/bin/bash ${INSTALL_DIR}/core/runner.sh
User=root
CPUSchedulingPolicy=idle
IOSchedulingClass=idle
EOF

    cat > /etc/systemd/system/ip-sentinel-runner.timer << EOF
[Unit]
Description=Timer for IP-Sentinel Runner Service
[Timer]
OnActiveSec=10s
OnUnitActiveSec=30min
RandomizedDelaySec=180
Persistent=true
Unit=ip-sentinel-runner.service
[Install]
WantedBy=timers.target
EOF

    # Updater 养料更新模块服务与定时器
    cat > /etc/systemd/system/ip-sentinel-updater.service << EOF
[Unit]
Description=IP-Sentinel Updater Service
After=network.target
[Service]
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
SyslogIdentifier=ip-sentinel
Type=oneshot
ExecStart=/bin/bash ${INSTALL_DIR}/core/updater.sh
User=root
CPUSchedulingPolicy=idle
IOSchedulingClass=idle
EOF

    cat > /etc/systemd/system/ip-sentinel-updater.timer << EOF
[Unit]
Description=Timer for IP-Sentinel Updater Service
[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true
Unit=ip-sentinel-updater.service
[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now ip-sentinel-runner.timer ip-sentinel-updater.timer

else
    echo "💡 未检测到 Systemd，回退到 Cron 调度模式..."
    crontab -l 2>/dev/null | grep -v "ip_sentinel" > /tmp/cron_backup || true
    echo "*/30 * * * * ${INSTALL_DIR}/core/runner.sh >/dev/null 2>&1" >> /tmp/cron_backup
    echo "0 3 * * * ${INSTALL_DIR}/core/updater.sh >/dev/null 2>&1" >> /tmp/cron_backup
    [ -f /tmp/cron_backup ] && crontab /tmp/cron_backup 2>/dev/null
    rm -f /tmp/cron_backup
fi

echo "========================================================"
if [ "$UPGRADE_MODE" == "true" ]; then
    echo "🎉 IP-Sentinel Lite 平滑热更新已彻底完成！"
else
    echo "🎉 IP-Sentinel Lite 部署流程彻底完成！"
fi
REGION_NAME_DISP=$(grep "^REGION_NAME=" "$CONFIG_FILE" | cut -d'"' -f2)
echo "📍 守护区域已锁定为: ${REGION_NAME_DISP}"
echo "⚙️ 哨兵现已开启 [每30分钟] 的高频高拟真 Google 区域纠偏循环。"
echo "📋 运行日志路径: ${INSTALL_DIR}/logs/sentinel.log"
echo "🗑️ 若未来需卸载，请执行: bash ${INSTALL_DIR}/core/uninstall.sh"
echo "========================================================"

# 匿名装机统计
echo -e "\n📡 正在向开源社区汇报装机量 (完全匿名，不收集IP)..."
AGENT_COUNT=$(curl -s -m 3 "https://ip-sentinel-count.samanthaestime296.workers.dev/ping/agent" || echo "")

if [ -n "$AGENT_COUNT" ] && [[ "$AGENT_COUNT" =~ ^[0-9]+$ ]]; then
    echo -e "\033[32m✅ 感谢您成为全球第 ${AGENT_COUNT} 名 IP-Sentinel 哨兵！\033[0m"
else
    echo -e "\033[32m✅ 感谢您加入 IP-Sentinel 哨兵阵列！\033[0m"
fi
echo -e "\n"

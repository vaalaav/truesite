#!/usr/bin/env bash
set -euo pipefail

# Цвета оформления
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

BACKUP_DIR="/root/vapen_cloud_backup"

log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $1"; }

echo -e "${CYAN}=================================================================${NC}"
echo -e "${GREEN}     VAPEN Cloud Storage — Enterprise Portal Deployer v2.1       ${NC}"
echo -e "${CYAN}=================================================================${NC}"

# 0. Проверка прав суперпользователя
if [[ $EUID -ne 0 ]]; then
   log_err "Запустите скрипт с правами root: sudo bash $0"
   exit 1
fi

# 1. Предварительная проверка системы (Pre-flight Check)
log_info "Запуск диагностики конфигурации сервера..."
READY=true

if ! command -v nginx >/dev/null 2>&1; then
    log_err "Nginx не установлен на сервере."
    READY=false
else
    NGINX_VER=$(nginx -v 2>&1 | awk -F'/' '{print $2}')
    log_ok "Установлен Nginx версии: $NGINX_VER"
fi

if systemctl is-active --quiet nginx; then
    log_ok "Служба Nginx активна и работает."
else
    log_warn "Служба Nginx не запущена (потребуется запуск)."
fi

if systemctl is-active --quiet x-ui; then
    log_ok "Обнаружена активная панель 3x-ui (x-ui.service) — настройки прокси не будут затронуты."
else
    log_info "Служба x-ui не обнаружена в systemd (или работает в изолированном режиме)."
fi

if ! nginx -t >/dev/null 2>&1; then
    log_err "Текущая конфигурация Nginx содержит синтаксические ошибки (nginx -t не проходит)."
    READY=false
else
    log_ok "Синтаксис текущих конфигов Nginx корректен."
fi

# Поиск активного конфига и папки сайта (root)
WEB_ROOT="/var/www/html"
TARGET_CONF=""

while IFS= read -r file; do
    if grep -qE "^\s*root\s+" "$file"; then
        TARGET_CONF="$file"
        DETECTED_ROOT=$(grep -E "^\s*root\s+" "$file" | head -n 1 | awk '{print $2}' | tr -d ';')
        [[ -n "$DETECTED_ROOT" ]] && WEB_ROOT="$DETECTED_ROOT"
        break
    fi
done < <(find /etc/nginx/sites-enabled /etc/nginx/conf.d -maxdepth 1 \( -type f -o -type l \) 2>/dev/null | sort)

if [[ -z "$TARGET_CONF" ]] && grep -qE "^\s*root\s+" /etc/nginx/nginx.conf; then
    TARGET_CONF="/etc/nginx/nginx.conf"
    DETECTED_ROOT=$(grep -E "^\s*root\s+" /etc/nginx/nginx.conf | head -n 1 | awk '{print $2}' | tr -d ';')
    [[ -n "$DETECTED_ROOT" ]] && WEB_ROOT="$DETECTED_ROOT"
fi

if [[ -n "$TARGET_CONF" ]]; then
    REAL_CONF=$(readlink -f "$TARGET_CONF")
    log_ok "Найден активный конфиг хоста: $REAL_CONF"
    log_ok "Определена директория сайта: $WEB_ROOT"
else
    log_warn "Не найден блок server с директивой root. Установка невозможна в автоматическом режиме."
    READY=false
fi

echo -e "${CYAN}-----------------------------------------------------------------${NC}"
if [[ "$READY" == true ]]; then
    echo -e "${GREEN}ВЕРДИКТ: Всё подходит для дальнейшей установки! Конфликтов не обнаружено.${NC}"
else
    echo -e "${RED}ВЕРДИКТ: Система НЕ готова к установке. Устраните ошибки выше и повторите запуск.${NC}"
    exit 1
fi
echo -e "${CYAN}-----------------------------------------------------------------${NC}"

# 2. Проверка наличия существующего бэкапа при повторном запуске
SKIP_BACKUP=false

if [[ -d "$BACKUP_DIR" ]] && [[ -f "$BACKUP_DIR/meta.env" ]]; then
    source "$BACKUP_DIR/meta.env"
    echo -e "${YELLOW}Обнаружена существующая резервная копия от: ${BACKUP_DATE}${NC}"
    echo "Выберите действие:"
    echo "  1) Восстановить исходную конфигурацию из этого бэкапа (Откат)"
    echo "  2) Продолжить установку/обновление VAPEN Cloud Storage (сохранить оригинальный бэкап)"
    echo "  3) Перезаписать бэкап текущим состоянием и продолжить установку"
    echo "  0) Выход"
    read -rp "Ваш выбор [1/2/3/0]: " USER_CHOICE

    case "$USER_CHOICE" in
        1)
            log_info "Восстановление исходной конфигурации из $BACKUP_DIR..."
            rm -rf "${SAVED_WEB_ROOT:?}/"*
            cp -a "$BACKUP_DIR/www/." "$SAVED_WEB_ROOT/"
            cp -a "$BACKUP_DIR/nginx/." /etc/nginx/
            rm -f /etc/nginx/snippets/vapen-cloud.conf
            if nginx -t >/dev/null 2>&1; then
                systemctl reload nginx
                log_ok "Исходная заглушка и конфигурация Nginx успешно восстановлены!"
                read -rp "Удалить папку использованного бэкапа $BACKUP_DIR? [y/N]: " DEL_BAK
                if [[ "$DEL_BAK" =~ ^[Yy]$ ]]; then
                    rm -rf "$BACKUP_DIR"
                    log_ok "Папка бэкапа удалена."
                fi
            else
                log_err "Ошибка при проверке nginx -t после восстановления! Проверьте /etc/nginx вручную."
            fi
            exit 0
            ;;
        2)
            log_info "Продолжаем установку (оригинальный бэкап сохранен)..."
            SKIP_BACKUP=true
            ;;
        3)
            log_info "Старый бэкап будет перезаписан текущим состоянием..."
            rm -rf "$BACKUP_DIR"
            SKIP_BACKUP=false
            ;;
        *)
            log_info "Операция отменена пользователем."
            exit 0
            ;;
    esac
fi

# 3. Создание бэкапа (если это первый запуск или выбрана перезапись)
if [[ "$SKIP_BACKUP" == false ]]; then
    log_info "Создание резервной копии текущей конфигурации в $BACKUP_DIR..."
    mkdir -p "$BACKUP_DIR/www" "$BACKUP_DIR/nginx"
    [[ -d "$WEB_ROOT" ]] && cp -a "$WEB_ROOT/." "$BACKUP_DIR/www/" 2>/dev/null || mkdir -p "$WEB_ROOT"
    cp -a /etc/nginx/. "$BACKUP_DIR/nginx/"
    cat << EOF_META > "$BACKUP_DIR/meta.env"
BACKUP_DATE="$(date '+%Y-%m-%d %H:%M:%S')"
SAVED_WEB_ROOT="$WEB_ROOT"
SAVED_CONF="$REAL_CONF"
EOF_META
    log_ok "Резервная копия успешно создана."
fi

# 4. Генерация портала VAPEN Cloud Storage
log_info "Развертывание веб-портала VAPEN Cloud Storage в $WEB_ROOT..."

cat << 'EOF_INDEX' > "${WEB_ROOT}/index.html"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <meta name="description" content="VAPEN Cloud Storage — Enterprise S3-Compatible Object Storage, Distributed NVMe Clusters, and Global Edge Content Delivery.">
  <meta name="keywords" content="VAPEN Cloud Storage, S3 Object Storage, NVMe Cloud, Distributed Storage, Zero-Knowledge Encryption, Edge CDN">
  <meta name="robots" content="index, follow">
  <meta property="og:title" content="VAPEN Cloud Storage | Enterprise Object Storage & Edge Network">
  <meta property="og:description" content="High-throughput S3-compatible NVMe object storage with immutable backups and global Anycast replication.">
  <meta property="og:type" content="website">
  <title>VAPEN Cloud Storage | Enterprise NVMe Object Storage & Edge Telemetry</title>
  <link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><text y='.9em' font-size='90'>☁️</text></svg>">
  <script type="application/ld+json">
  {
    "@context": "https://schema.org",
    "@type": "Organization",
    "name": "VAPEN Cloud Storage",
    "description": "Enterprise S3 Object Storage and Distributed Edge Infrastructure",
    "url": "https://vapen-storage.internal"
  }
  </script>
  <style>
    :root {
      --bg-main: #060911;
      --bg-card: #0f1626;
      --bg-card-hover: #151f36;
      --border: #1e293b;
      --text-main: #f8fafc;
      --text-muted: #94a3b8;
      --accent: #3b82f6;
      --accent-glow: rgba(59, 130, 246, 0.25);
      --success: #10b981;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      background-color: var(--bg-main);
      color: var(--text-main);
      font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      line-height: 1.6;
    }
    header {
      border-bottom: 1px solid var(--border);
      background: rgba(6, 9, 17, 0.85);
      backdrop-filter: blur(10px);
      position: sticky;
      top: 0;
      z-index: 100;
    }
    .container { max-width: 1200px; margin: 0 auto; padding: 0 1.5rem; }
    .nav-bar { display: flex; justify-content: space-between; align-items: center; height: 70px; }
    .logo { font-weight: 700; font-size: 1.25rem; display: flex; align-items: center; gap: 10px; color: var(--text-main); text-decoration: none; letter-spacing: 0.02em; }
    .logo-badge { background: var(--accent); color: #fff; font-size: 0.7rem; padding: 2px 7px; border-radius: 4px; text-transform: uppercase; }
    nav ul { display: flex; list-style: none; gap: 2rem; }
    nav a { color: var(--text-muted); text-decoration: none; font-size: 0.95rem; transition: color 0.2s; }
    nav a:hover { color: var(--text-main); }
    .nav-actions { display: flex; align-items: center; gap: 1rem; }
    .btn { padding: 0.5rem 1.1rem; border-radius: 6px; font-size: 0.9rem; font-weight: 500; cursor: pointer; border: 1px solid transparent; transition: all 0.2s; text-decoration: none; }
    .btn-outline { border-color: var(--border); background: transparent; color: var(--text-main); }
    .btn-outline:hover { background: var(--bg-card); }
    .btn-primary { background: var(--accent); color: #fff; box-shadow: 0 0 15px var(--accent-glow); }
    .btn-primary:hover { background: #2563eb; }
    .hero { padding: 4.5rem 0 3rem; border-bottom: 1px solid var(--border); background: radial-gradient(circle at 50% 0%, #111d38 0%, var(--bg-main) 70%); }
    .hero-grid { display: grid; grid-template-columns: 1.2fr 0.8fr; gap: 3rem; align-items: center; }
    .status-pill { display: inline-flex; align-items: center; gap: 10px; background: rgba(16, 185, 129, 0.1); border: 1px solid rgba(16, 185, 129, 0.3); padding: 6px 14px; border-radius: 999px; font-size: 0.85rem; color: #34d399; margin-bottom: 1.5rem; }
    .dot { width: 9px; height: 9px; background-color: var(--success); border-radius: 50%; display: inline-block; animation: pulse 2s infinite; }
    @keyframes pulse {
      0% { transform: scale(0.95); box-shadow: 0 0 0 0 rgba(16, 185, 129, 0.7); }
      70% { transform: scale(1); box-shadow: 0 0 0 8px rgba(16, 185, 129, 0); }
      100% { transform: scale(0.95); box-shadow: 0 0 0 0 rgba(16, 185, 129, 0); }
    }
    h1 { font-size: 2.75rem; line-height: 1.2; margin-bottom: 1.25rem; letter-spacing: -0.02em; }
    .hero p { color: var(--text-muted); font-size: 1.1rem; margin-bottom: 2rem; max-width: 580px; }
    .telemetry-card { background: var(--bg-card); border: 1px solid var(--border); border-radius: 12px; padding: 1.5rem; box-shadow: 0 20px 40px rgba(0,0,0,0.4); }
    .telemetry-header { display: flex; justify-content: space-between; align-items: center; padding-bottom: 1rem; border-bottom: 1px solid var(--border); margin-bottom: 1rem; font-size: 0.9rem; }
    .metric-grid { display: grid; grid-template-columns: repeat(2, 1fr); gap: 1rem; margin-bottom: 1rem; }
    .metric-box { background: rgba(255,255,255,0.02); border: 1px solid var(--border); padding: 0.85rem; border-radius: 8px; }
    .metric-label { font-size: 0.75rem; color: var(--text-muted); text-transform: uppercase; letter-spacing: 0.05em; }
    .metric-val { font-size: 1.35rem; font-weight: 700; font-family: monospace; color: var(--text-main); margin-top: 4px; }
    .clock-bar { font-family: monospace; font-size: 0.82rem; color: var(--text-muted); display: flex; justify-content: space-between; padding-top: 0.75rem; border-top: 1px solid var(--border); }
    .section { padding: 4rem 0; border-bottom: 1px solid var(--border); }
    .section-title { font-size: 1.75rem; margin-bottom: 0.5rem; }
    .section-sub { color: var(--text-muted); margin-bottom: 2rem; }
    .table-wrap { background: var(--bg-card); border: 1px solid var(--border); border-radius: 12px; overflow: hidden; }
    table { width: 100%; border-collapse: collapse; text-align: left; font-size: 0.92rem; }
    th, td { padding: 1rem 1.25rem; border-bottom: 1px solid var(--border); }
    th { background: rgba(255,255,255,0.02); color: var(--text-muted); font-weight: 600; font-size: 0.8rem; text-transform: uppercase; }
    tr:last-child td { border-bottom: none; }
    .badge-ok { background: rgba(16, 185, 129, 0.15); color: #34d399; padding: 3px 8px; border-radius: 4px; font-size: 0.78rem; font-family: monospace; }
    .grid-3 { display: grid; grid-template-columns: repeat(3, 1fr); gap: 1.5rem; }
    .card { background: var(--bg-card); border: 1px solid var(--border); border-radius: 10px; padding: 1.5rem; transition: background 0.2s; }
    .card:hover { background: var(--bg-card-hover); }
    .card h3 { font-size: 1.15rem; margin-bottom: 0.6rem; }
    .card p { color: var(--text-muted); font-size: 0.9rem; }
    .calc-box { background: var(--bg-card); border: 1px solid var(--border); border-radius: 12px; padding: 2rem; margin-top: 2rem; display: flex; justify-content: space-between; align-items: center; gap: 2rem; }
    input[type="range"] { width: 100%; accent-color: var(--accent); margin-top: 0.75rem; }
    .modal-backdrop { display: none; position: fixed; inset: 0; background: rgba(0,0,0,0.75); z-index: 200; align-items: center; justify-content: center; }
    .modal { background: var(--bg-card); border: 1px solid var(--border); border-radius: 12px; width: 100%; max-width: 400px; padding: 2rem; }
    .modal input { width: 100%; padding: 0.65rem; margin: 0.5rem 0 1rem; background: var(--bg-main); border: 1px solid var(--border); color: #fff; border-radius: 6px; }
    footer { padding: 3rem 0; color: var(--text-muted); font-size: 0.85rem; }
    .footer-grid { display: grid; grid-template-columns: 2fr 1fr 1fr 1fr; gap: 2rem; margin-bottom: 2rem; }
    .footer-col h4 { color: var(--text-main); margin-bottom: 0.75rem; font-size: 0.95rem; }
    .footer-col ul { list-style: none; }
    .footer-col li { margin-bottom: 0.4rem; }
    .footer-col a { color: var(--text-muted); text-decoration: none; }
    @media (max-width: 768px) {
      .hero-grid, .grid-3, .footer-grid, .calc-box { grid-template-columns: 1fr; flex-direction: column; }
      nav ul { display: none; }
    }
  </style>
</head>
<body>
<header>
  <div class="container nav-bar">
    <a href="#" class="logo">☁️ VAPEN Cloud Storage <span class="logo-badge">S3 Edge v4.2</span></a>
    <nav>
      <ul>
        <li><a href="#network">Storage Clusters</a></li>
        <li><a href="#products">Architecture</a></li>
        <li><a href="#calculator">Volume Pricing</a></li>
        <li><a href="/api/v1/health" target="_blank">API Health</a></li>
        <li><a href="#docs" onclick="openModal(); return false;">S3 API Docs</a></li>
      </ul>
    </nav>
    <div class="nav-actions">
      <button class="btn btn-outline" onclick="openModal()">Tenant SSO</button>
      <button class="btn btn-primary" onclick="openModal()">Storage Console</button>
    </div>
  </div>
</header>
<section class="hero">
  <div class="container hero-grid">
    <div>
      <div class="status-pill">
        <span class="dot"></span>
        <span>All NVMe Object Clusters Operational • TLS 1.3 Enforced</span>
      </div>
      <h1>High-Throughput S3 Object Storage & Edge Fabric</h1>
      <p>Deploy immutable enterprise backups, zero-egress distributed buckets, and low-latency edge caching with 99.999999999% (11 9s) data durability across global availability zones.</p>
      <div style="display: flex; gap: 1rem;">
        <a href="#network" class="btn btn-primary">Cluster Telemetry</a>
        <a href="#calculator" class="btn btn-outline">Estimate Storage Cost</a>
      </div>
    </div>
    <div class="telemetry-card">
      <div class="telemetry-header">
        <strong>⚡ Local Storage Node Telemetry</strong>
        <span class="badge-ok">S3 / HTTP3 QUIC</span>
      </div>
      <div class="metric-grid">
        <div class="metric-box">
          <div class="metric-label">Cluster Egress</div>
          <div class="metric-val" id="m-bw">44.2 Gbps</div>
        </div>
        <div class="metric-box">
          <div class="metric-label">S3 PUT/GET IOPS</div>
          <div class="metric-val" id="m-req">24,810 ops</div>
        </div>
        <div class="metric-box">
          <div class="metric-label">NVMe Pool Load</div>
          <div class="metric-val" id="m-cpu">16.4%</div>
        </div>
        <div class="metric-box">
          <div class="metric-label">Time to First Byte</div>
          <div class="metric-val" id="m-ping">1.9 ms</div>
        </div>
      </div>
      <div class="clock-bar">
        <span id="clock">Syncing NTP...</span>
        <span id="ray-id">NodeID: initializing...</span>
      </div>
    </div>
  </div>
</section>
<section id="network" class="section">
  <div class="container">
    <h2 class="section-title">Multi-Region Replication Status</h2>
    <p class="section-sub">Real-time erasure coding health and backbone synchronization across primary Tier-4 VAPEN storage vaults.</p>
    <div class="table-wrap">
      <table>
        <thead>
          <tr>
            <th>Vault ID</th>
            <th>Availability Zone</th>
            <th>Replication Mode</th>
            <th>NVMe Latency</th>
            <th>Cluster State</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td><strong>VPN-FRA-01</strong></td>
            <td>Frankfurt, DE (EU-Central)</td>
            <td>S3 Multi-AZ / AES-256-GCM</td>
            <td>1.8 ms</td>
            <td><span class="badge-ok">200 OK • Synced</span></td>
          </tr>
          <tr>
            <td><strong>VPN-AMS-04</strong></td>
            <td>Amsterdam, NL (EU-West)</td>
            <td>S3 Multi-AZ / AES-256-GCM</td>
            <td>2.9 ms</td>
            <td><span class="badge-ok">200 OK • Synced</span></td>
          </tr>
          <tr>
            <td><strong>VPN-HEL-02</strong></td>
            <td>Helsinki, FI (Nordic-Core)</td>
            <td>S3 Multi-AZ / AES-256-GCM</td>
            <td>4.6 ms</td>
            <td><span class="badge-ok">200 OK • Synced</span></td>
          </tr>
          <tr>
            <td><strong>VPN-IAD-09</strong></td>
            <td>Ashburn, US (US-East)</td>
            <td>S3 Cross-Region / Async</td>
            <td>17.4 ms</td>
            <td><span class="badge-ok">200 OK • Synced</span></td>
          </tr>
          <tr>
            <td><strong>VPN-SIN-03</strong></td>
            <td>Singapore (APAC-Hub)</td>
            <td>S3 Cross-Region / Async</td>
            <td>29.8 ms</td>
            <td><span class="badge-ok">200 OK • Synced</span></td>
          </tr>
        </tbody>
      </table>
    </div>
  </div>
</section>
<section id="products" class="section">
  <div class="container">
    <h2 class="section-title">VAPEN Enterprise Storage Stack</h2>
    <p class="section-sub">Engineered for AI dataset training, Kubernetes persistent volumes, and immutable archival.</p>
    <div class="grid-3">
      <div class="card">
        <h3>🗄️ 100% S3-Compatible API</h3>
        <p>Drop-in replacement for AWS S3. Native support for Terraform, rclone, Veeam, and Kubernetes CSI drivers with zero code changes.</p>
      </div>
      <div class="card">
        <h3>⚡ All-NVMe Erasure Coding</h3>
        <p>Distributed Reed-Solomon parity across independent fault domains guarantees instant recovery without degraded read performance.</p>
      </div>
      <div class="card">
        <h3>🔒 Object Lock & Zero-Trust</h3>
        <p>WORM (Write-Once-Read-Many) ransomware protection, client-side KMS encryption keys, and hardware mTLS bucket policies.</p>
      </div>
    </div>
    <div id="calculator" class="calc-box">
      <div style="flex: 1;">
        <h3>Enterprise Storage Volume Estimator</h3>
        <p style="color: var(--text-muted); font-size: 0.9rem;">Slide to calculate monthly flat-rate provisioning for dedicated NVMe object storage (zero egress fees).</p>
        <input type="range" id="bw-slider" min="10" max="1000" step="10" value="150" oninput="updateCalc(this.value)">
      </div>
      <div style="text-align: right; min-width: 240px;">
        <div class="metric-label">Reserved Capacity</div>
        <div class="metric-val" id="calc-out" style="color: var(--accent);">150 TB / $1,050 mo</div>
      </div>
    </div>
  </div>
</section>
<footer>
  <div class="container">
    <div class="footer-grid">
      <div class="footer-col">
        <h4>☁️ VAPEN Cloud Storage</h4>
        <p>Enterprise distributed NVMe object storage, S3 edge caching, and encrypted archival infrastructure. ISO/IEC 27001 & SOC2 Type II Certified.</p>
      </div>
      <div class="footer-col">
        <h4>Infrastructure</h4>
        <ul>
          <li><a href="#network">S3 Object Storage</a></li>
          <li><a href="#products">NVMe Block Volumes</a></li>
          <li><a href="/api/v1/health" target="_blank">Node Health API</a></li>
        </ul>
      </div>
      <div class="footer-col">
        <h4>Compliance</h4>
        <ul>
          <li><a href="#" onclick="openModal(); return false;">GDPR Data Processing</a></li>
          <li><a href="#" onclick="openModal(); return false;">99.999% SLA Policy</a></li>
          <li><a href="#" onclick="openModal(); return false;">Security Whitepaper</a></li>
        </ul>
      </div>
      <div class="footer-col">
        <h4>Network</h4>
        <ul>
          <li>NOC: 24/7/365 Active</li>
          <li>AS-Number: AS398102</li>
          <li>S3 Endpoint: Active</li>
        </ul>
      </div>
    </div>
    <div style="border-top: 1px solid var(--border); padding-top: 1.5rem; display: flex; justify-content: space-between;">
      <span>© 2026 VAPEN Cloud Storage. All rights reserved.</span>
      <span>TLS 1.3 End-to-End Encrypted Session</span>
    </div>
  </div>
</footer>
<div class="modal-backdrop" id="auth-modal">
  <div class="modal">
    <h3 style="margin-bottom: 0.5rem;">VAPEN Storage Console</h3>
    <p style="color: var(--text-muted); font-size: 0.85rem; margin-bottom: 1rem;">Sign in with your Tenant Access Key or Corporate SAML 2.0 SSO.</p>
    <form onsubmit="handleAuth(event)">
      <label style="font-size: 0.8rem; color: var(--text-muted);">Tenant ID / Corporate Email</label>
      <input type="email" required placeholder="admin@tenant-storage.io">
      <label style="font-size: 0.8rem; color: var(--text-muted);">Secret Access Key / YubiKey OTP</label>
      <input type="password" required placeholder="••••••••••••••••">
      <p id="auth-err" style="color: #f87171; font-size: 0.8rem; display: none; margin-bottom: 0.75rem;">Error 403 (AccessDenied): Client IP is not authorized in this bucket's VPC policy.</p>
      <div style="display: flex; justify-content: flex-end; gap: 0.5rem;">
        <button type="button" class="btn btn-outline" onclick="closeModal()">Cancel</button>
        <button type="submit" class="btn btn-primary">Authenticate</button>
      </div>
    </form>
  </div>
</div>
<script>
  const rayHex = Array.from({length: 16}, () => Math.floor(Math.random()*16).toString(16)).join('');
  document.getElementById('ray-id').textContent = 'ReqID: ' + rayHex.toUpperCase();
  function updateClock() {
    const now = new Date();
    document.getElementById('clock').textContent = now.toISOString().replace('T', ' ').substring(0, 19) + ' UTC';
  }
  setInterval(updateClock, 1000);
  updateClock();
  setInterval(() => {
    const bw = (42 + Math.random() * 4.5).toFixed(1);
    const req = Math.floor(24100 + Math.random() * 1800).toLocaleString();
    const cpu = (14 + Math.random() * 5).toFixed(1);
    const ping = (1.7 + Math.random() * 0.4).toFixed(1);
    document.getElementById('m-bw').textContent = bw + ' Gbps';
    document.getElementById('m-req').textContent = req + ' ops';
    document.getElementById('m-cpu').textContent = cpu + '%';
    document.getElementById('m-ping').textContent = ping + ' ms';
  }, 2500);
  function updateCalc(val) {
    const price = (val * 7).toLocaleString();
    document.getElementById('calc-out').textContent = val + ' TB / $' + price + ' mo';
  }
  function openModal() {
    document.getElementById('auth-err').style.display = 'none';
    document.getElementById('auth-modal').style.display = 'flex';
  }
  function closeModal() {
    document.getElementById('auth-modal').style.display = 'none';
  }
  function handleAuth(e) {
    e.preventDefault();
    document.getElementById('auth-err').style.display = 'block';
  }
</script>
</body>
</html>
EOF_INDEX

cat << 'EOF_ERROR' > "${WEB_ROOT}/error.html"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <meta name="robots" content="noindex, nofollow">
  <title>VAPEN Cloud Storage | S3 Gateway Security Exception</title>
  <link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><text y='.9em' font-size='90'>🛡️</text></svg>">
  <style>
    :root {
      --bg-main: #060911;
      --bg-card: #0f1626;
      --border: #1e293b;
      --text-main: #f8fafc;
      --text-muted: #94a3b8;
      --accent: #3b82f6;
      --warn: #f59e0b;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      background-color: var(--bg-main);
      color: var(--text-main);
      font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      min-height: 100vh;
      display: flex;
      flex-direction: column;
      justify-content: space-between;
      background-image: radial-gradient(circle at 50% 0%, #17152b 0%, var(--bg-main) 65%);
    }
    header { border-bottom: 1px solid var(--border); padding: 1.2rem 2rem; display: flex; justify-content: space-between; align-items: center; }
    .logo { font-weight: 700; font-size: 1.15rem; color: var(--text-main); text-decoration: none; display: flex; align-items: center; gap: 8px; }
    .badge { background: rgba(245, 158, 11, 0.15); border: 1px solid rgba(245, 158, 11, 0.4); color: var(--warn); font-size: 0.75rem; padding: 3px 10px; border-radius: 999px; font-family: monospace; }
    main { max-width: 680px; width: 100%; margin: 3rem auto; padding: 0 1.5rem; }
    .waf-card { background: var(--bg-card); border: 1px solid var(--border); border-radius: 12px; padding: 2.25rem; box-shadow: 0 20px 45px rgba(0,0,0,0.5); }
    .code-row { display: flex; align-items: center; gap: 12px; margin-bottom: 1rem; }
    .status-dot { width: 12px; height: 12px; border-radius: 50%; background: var(--warn); box-shadow: 0 0 12px var(--warn); }
    h1 { font-size: 1.65rem; letter-spacing: -0.01em; }
    p.desc { color: var(--text-muted); font-size: 0.95rem; line-height: 1.6; margin-bottom: 1.5rem; }
    .diag-box { background: #090d16; border: 1px solid var(--border); border-radius: 8px; padding: 1.1rem; font-family: monospace; font-size: 0.82rem; color: #cbd5e1; margin-bottom: 1.5rem; line-height: 1.7; overflow-x: auto; }
    .diag-key { color: var(--text-muted); display: inline-block; width: 160px; }
    .actions { display: flex; gap: 1rem; align-items: center; }
    .btn { padding: 0.6rem 1.25rem; border-radius: 6px; font-size: 0.9rem; font-weight: 500; text-decoration: none; transition: all 0.2s; }
    .btn-primary { background: var(--accent); color: #fff; }
    .btn-primary:hover { background: #2563eb; }
    .btn-outline { border: 1px solid var(--border); color: var(--text-muted); }
    .btn-outline:hover { color: var(--text-main); background: rgba(255,255,255,0.03); }
    footer { border-top: 1px solid var(--border); padding: 1.25rem 2rem; text-align: center; color: var(--text-muted); font-size: 0.8rem; }
  </style>
</head>
<body>
<header>
  <a href="/" class="logo">☁️ VAPEN Cloud Storage <span style="color: var(--text-muted); font-weight: 400;">| S3 WAF</span></a>
  <span class="badge">ERR_CODE: NoSuchBucketOrPolicy</span>
</header>
<main>
  <div class="waf-card">
    <div class="code-row">
      <span class="status-dot"></span>
      <h1>S3 Bucket Route Restricted / Unmapped URI</h1>
    </div>
    <p class="desc">
      The requested object key or endpoint does not exist on this storage gateway, or your request lacks a valid AWS4-HMAC-SHA256 authorization signature.
    </p>
    <div class="diag-box">
      <div><span class="diag-key">Gateway Status:</span> <span style="color: #f87171;">403 / 404 Filtered by S3 Object Policy</span></div>
      <div><span class="diag-key">Requested Object:</span> <span id="req-path">/</span></div>
      <div><span class="diag-key">WAF Action:</span> <span>DENY_UNSIGNED_S3_REQUEST</span></div>
      <div><span class="diag-key">VAPEN Trace ID:</span> <span id="trace-id">generating...</span></div>
      <div><span class="diag-key">Timestamp (UTC):</span> <span id="ts">syncing...</span></div>
    </div>
    <div class="actions">
      <a href="/" class="btn btn-primary">← Return to Storage Portal</a>
      <a href="/" class="btn btn-outline">Check Cluster Status</a>
    </div>
  </div>
</main>
<footer>
  Protected by VAPEN Cloud Storage Autonomous WAF • TLS 1.3 Strict Enforcement • AS398102
</footer>
<script>
  document.getElementById('req-path').textContent = window.location.pathname;
  const trace = Array.from({length: 20}, () => Math.floor(Math.random()*16).toString(16)).join('').toUpperCase();
  document.getElementById('trace-id').textContent = 'VPN-' + trace.slice(0,8) + '-' + trace.slice(8,16);
  document.getElementById('ts').textContent = new Date().toISOString();
</script>
</body>
</html>
EOF_ERROR

cat << 'EOF_ROBOTS' > "${WEB_ROOT}/robots.txt"
User-agent: *
Disallow: /s3/
Disallow: /buckets/
Disallow: /console/
Disallow: /sso/
Allow: /api/v1/health
Allow: /
EOF_ROBOTS

chmod 644 "${WEB_ROOT}/index.html" "${WEB_ROOT}/error.html" "${WEB_ROOT}/robots.txt"
log_ok "Файлы портала VAPEN Cloud Storage успешно записаны."

# 5. Настройка сниппета заголовков Nginx (включая /s3 XML и /api/v1/health JSON)
log_info "Формирование сниппета /etc/nginx/snippets/vapen-cloud.conf..."

mkdir -p /etc/nginx/snippets
cat << EOF_SNIPPET > /etc/nginx/snippets/vapen-cloud.conf
# Перехват ошибок на экран WAF VAPEN Cloud Storage
error_page 403 404 500 502 503 504 /error.html;
location = /error.html {
    root ${WEB_ROOT};
    internal;
}

# Эмуляция S3 Object Storage API (AWS S3 / MinIO XML Response)
location ~ ^/(s3|buckets)(/.*)?\$ {
    default_type application/xml;
    add_header x-amz-request-id \$request_id always;
    add_header x-amz-id-2 "MzRISOwyjmnup+\$request_id/VAPEN/s3-eu-central-1" always;
    add_header x-amz-bucket-region "eu-central-1" always;
    add_header Server "VAPEN-S3-Gateway" always;
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
    add_header X-Content-Type-Options "nosniff" always;

    return 403 '<?xml version="1.0" encoding="UTF-8"?>\n<Error>\n  <Code>AccessDenied</Code>\n  <Message>Access Denied. Unsigned request or missing AWS4-HMAC-SHA256 authorization header.</Message>\n  <Resource>\$uri</Resource>\n  <RequestId>\$request_id</RequestId>\n  <HostId>MzRISOwyjmnup+\$request_id/VAPEN-S3-FRA01</HostId>\n</Error>\n';
}

# Эмуляция JSON-эндпоинта телеметрии и статуса узла (/api/v1/health)
location = /api/v1/health {
    default_type application/json;
    add_header Cache-Control "no-store, no-cache, must-revalidate" always;
    add_header X-Vapen-Request-ID \$request_id always;
    add_header X-S3-Storage-Node "VPN-FRA-01" always;
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
    add_header X-Content-Type-Options "nosniff" always;

    return 200 '{"status":"healthy","service":"VAPEN Cloud Storage S3 Gateway","version":"4.2.1-enterprise","node_id":"VPN-FRA-01","region":"eu-central-1","storage_engine":"nvme-erasure-coding-v4","replication":"synced","tls_protocol":"\$ssl_protocol","timestamp":"\$time_iso8601","request_id":"\$request_id"}\n';
}

# Заголовки безопасности и S3/CDN телеметрии VAPEN Cloud Storage
add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Permissions-Policy "accelerometer=(), camera=(), geolocation=(), gyroscope=(), magnetometer=(), microphone=(), payment=(), usb=()" always;
add_header Cross-Origin-Opener-Policy "same-origin" always;
add_header Cross-Origin-Resource-Policy "same-origin" always;
add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self';" always;
add_header X-Vapen-Request-ID \$request_id always;
add_header X-S3-Storage-Node "VPN-FRA-01" always;
add_header X-Cache-Status "HIT" always;
add_header X-WAF-Engine "VAPEN-Shield/4.2" always;
add_header Timing-Allow-Origin "*" always;
EOF_SNIPPET

# Отключаем server_tokens в nginx.conf
if grep -qE "^\s*#\s*server_tokens\s+off;" /etc/nginx/nginx.conf; then
    sed -i 's/^\(\s*\)#\s*server_tokens\s\+off;/\1server_tokens off;/' /etc/nginx/nginx.conf
    log_ok "Скрыта версия веб-сервера (server_tokens off)."
fi

# Подключаем сниппет в целевой конфиг
if grep -q "snippets/cloudvantage.conf" "$REAL_CONF"; then
    sed -i 's|snippets/cloudvantage.conf|snippets/vapen-cloud.conf|g' "$REAL_CONF"
    log_ok "Обновлена ссылка на сниппет vapen-cloud.conf в $REAL_CONF."
elif grep -q "snippets/vapen-cloud.conf" "$REAL_CONF"; then
    log_info "Сниппет vapen-cloud.conf уже подключен в $REAL_CONF."
else
    sed -i '/^\s*root\s\+/a \    include /etc/nginx/snippets/vapen-cloud.conf;' "$REAL_CONF"
    log_ok "Сниппет vapen-cloud.conf подключен в $REAL_CONF."
fi

# 6. Тестирование и применение
log_info "Финальная проверка конфигурации Nginx (nginx -t)..."

if nginx -t >/dev/null 2>&1; then
    systemctl reload nginx
    log_ok "Nginx успешно перезагружен! Портал VAPEN Cloud Storage активен."
else
    log_warn "Обнаружена ошибка в синтаксисе Nginx! Выполняется автоматический откат..."
    cp -a "$BACKUP_DIR/nginx/." /etc/nginx/
    cp -a "$BACKUP_DIR/www/." "$WEB_ROOT/"
    systemctl reload nginx
    log_err "Изменения отменены, восстановлена исходная конфигурация."
    exit 1
fi

echo -e "${CYAN}=================================================================${NC}"
echo -e "${GREEN} Готово! Портал VAPEN Cloud Storage v2.1 успешно развернут.${NC}"
echo -e " • Директория сайта: ${YELLOW}${WEB_ROOT}${NC}"
echo -e " • Постоянный бэкап: ${YELLOW}${BACKUP_DIR}${NC}"
echo -e " • Проверка S3 XML:  ${YELLOW}curl -i http://127.0.0.1/s3/bucket-01${NC}"
echo -e " • Проверка Health:  ${YELLOW}curl -i http://127.0.0.1/api/v1/health${NC}"
echo -e " • Повторный запуск ${YELLOW}sudo ./deploy-vapen.sh${NC} откроет меню отката."
echo -e "${CYAN}=================================================================${NC}"

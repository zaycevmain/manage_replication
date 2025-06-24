#!/bin/bash
# Скрипт управления репликацией PostgreSQL и синхронизацией файлов

# Константы
CONFIG_FILE="replication.conf"
LOG_FILE="/var/log/file_sync.log"
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Функции логирования
log_info()   { echo -e "${GREEN}[INFO]${NC} $1" >&2; }
log_warn()   { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
log_error()  { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# Загрузка конфигурации
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        log_info "Конфигурация загружена из $CONFIG_FILE"
        return 0
    else
        log_warn "Файл конфигурации $CONFIG_FILE не найден. Сначала настройте параметры (опция 1)."
        return 1
    fi
}

# Выполнение SSH команды без eval
execute_ssh() {
    local host="$1"
    local cmd="$2"
    
    if [ "$SSH_AUTH_METHOD" = "password" ]; then
        if ! command -v sshpass >/dev/null 2>&1; then
            log_error "Утилита 'sshpass' не найдена, но выбрана аутентификация по паролю."
            return 1
        fi
        sshpass -p "$SSH_PASSWORD" ssh -o StrictHostKeyChecking=no "$SSH_USER@$host" "$cmd"
    else
        ssh -o StrictHostKeyChecking=no "$SSH_USER@$host" "$cmd"
    fi
    return $?
}

# Проверка SSH доступа
check_ssh_access() {
    local host="$1"
    execute_ssh "$host" "echo 'SSH connection test successful'" >/dev/null 2>&1
}

# Настройка параметров
configure_params() {
    clear
    echo "============================================="
    echo "    1. Настройка параметров резервирования   "
    echo "============================================="
    
    # Создание файла конфигурации
    > "$CONFIG_FILE"
    echo "# Файл конфигурации для скрипта управления репликацией" >> "$CONFIG_FILE"
    echo "# Создан $(date)" >> "$CONFIG_FILE"
    echo "" >> "$CONFIG_FILE"
    
    # Выбор метода SSH аутентификации
    log_info "Выберите метод SSH аутентификации."
    select auth_method in "Ключ (рекомендуется)" "Пароль (небезопасно)"; do
        case $auth_method in
            "Ключ (рекомендуется)")
                echo "SSH_AUTH_METHOD=\"key\"" >> "$CONFIG_FILE"
                break
                ;;
            "Пароль (небезопасно)")
                echo "SSH_AUTH_METHOD=\"password\"" >> "$CONFIG_FILE"
                read -sp "Введите пароль для SSH: " ssh_password
                echo
                log_warn "ВНИМАНИЕ: Пароль будет сохранен в открытом виде!"
                echo "SSH_PASSWORD=\"$ssh_password\"" >> "$CONFIG_FILE"
                break
                ;;
        esac
    done
    
    # Ввод параметров
    read -p "Имя пользователя для SSH: " ssh_user
    echo "SSH_USER=\"$ssh_user\"" >> "$CONFIG_FILE"
    
    read -p "IP основного сервера приложений: " primary_app_ip
    echo "PRIMARY_APP_IP=\"$primary_app_ip\"" >> "$CONFIG_FILE"
    
    read -p "IP основного сервера PostgreSQL: " primary_db_ip
    echo "PRIMARY_DB_IP=\"$primary_db_ip\"" >> "$CONFIG_FILE"
    
    read -p "IP резервного сервера приложений: " backup_app_ip
    echo "BACKUP_APP_IP=\"$backup_app_ip\"" >> "$CONFIG_FILE"
    
    read -p "IP резервного сервера PostgreSQL: " backup_db_ip
    echo "BACKUP_DB_IP=\"$backup_db_ip\"" >> "$CONFIG_FILE"
    
    read -p "Порт PostgreSQL [5432]: " primary_db_port
    primary_db_port=${primary_db_port:-5432}
    echo "PRIMARY_DB_PORT=\"$primary_db_port\"" >> "$CONFIG_FILE"
    
    read -p "Имя суперпользователя PostgreSQL [postgres]: " primary_db_super_user
    primary_db_super_user=${primary_db_super_user:-postgres}
    echo "PRIMARY_DB_SUPER_USER=\"$primary_db_super_user\"" >> "$CONFIG_FILE"
    
    read -sp "Пароль суперпользователя PostgreSQL: " primary_db_super_pass
    echo
    echo "PRIMARY_DB_SUPER_PASS=\"$primary_db_super_pass\"" >> "$CONFIG_FILE"
    
    read -p "Имя пользователя для репликации [replication_user]: " repl_user
    repl_user=${repl_user:-replication_user}
    echo "REPL_USER=\"$repl_user\"" >> "$CONFIG_FILE"
    
    read -sp "Пароль для пользователя репликации: " repl_pass
    echo
    echo "REPL_PASS=\"$repl_pass\"" >> "$CONFIG_FILE"
    
    # Настройка директорий для синхронизации
    log_info "Укажите директории для синхронизации. Enter на пустой строке — закончить."
    declare -a sync_dirs_source
    declare -a sync_dirs_target
    i=0
    
    while true; do
        read -p "Путь к исходной папке на сервере ${primary_app_ip}: " source_dir
        [ -z "$source_dir" ] && break
        
        read -p "Путь к папке назначения на сервере ${backup_app_ip}: " target_dir
        [ -z "$target_dir" ] && log_warn "Путь назначения не может быть пустым. Пропускаем." && continue
        
        sync_dirs_source[$i]=$source_dir
        sync_dirs_target[$i]=$target_dir
        i=$((i+1))
    done
    
    echo "SYNC_DIRS_SOURCE=(${sync_dirs_source[@]})" >> "$CONFIG_FILE"
    echo "SYNC_DIRS_TARGET=(${sync_dirs_target[@]})" >> "$CONFIG_FILE"
    
    log_info "Настройка завершена. Конфигурация сохранена в $CONFIG_FILE"
    read -p "Нажмите Enter для возврата в меню..."
}

# Настройка синхронизации файлов
setup_file_sync() {
    log_info "=== НАЧАЛО НАСТРОЙКИ СИНХРОНИЗАЦИИ ФАЙЛОВ ==="
    
    log_info "Настройка синхронизации файлов..."
    
    # Проверка SSH доступа
    log_info "Проверка SSH доступа к резервному серверу приложений..."
    if ! check_ssh_access "$BACKUP_APP_IP"; then
        log_error "Нет SSH доступа к резервному серверу приложений"
        return 1
    fi
    log_info "SSH доступ к резервному серверу приложений подтвержден"
    
    # Установка зависимостей
    log_info "Установка зависимостей на резервном сервере..."
    execute_ssh "$BACKUP_APP_IP" "sudo apt-get update && sudo apt-get install -y openjdk-17-jdk rsync" || return 1
    log_info "Зависимости установлены"
    
    # Создание директорий
    for target_dir in "${SYNC_DIRS_TARGET[@]}"; do
        execute_ssh "$BACKUP_APP_IP" "sudo mkdir -p $target_dir" || return 1
    done
    
    # Создание скрипта синхронизации
    cat > sync_files.sh << 'EOF'
#!/bin/bash
# Скрипт синхронизации файлов

# Загрузка конфигурации
if [ -f "replication.conf" ]; then
    source replication.conf
else
    echo "❌ Файл replication.conf не найден"
    exit 1
fi

# Настройка лога
LOG_FILE="/var/log/file_sync.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

echo "[$TIMESTAMP] Начало синхронизации файлов" >> "$LOG_FILE"

# Синхронизация каждой пары директорий
for i in "${!SYNC_DIRS_SOURCE[@]}"; do
    source_dir="${SYNC_DIRS_SOURCE[$i]}"
    target_dir="${SYNC_DIRS_TARGET[$i]}"
    
    echo "[$TIMESTAMP] Синхронизация: $source_dir -> $BACKUP_APP_IP:$target_dir" >> "$LOG_FILE"
    
    if [ "$SSH_AUTH_METHOD" = "password" ]; then
        rsync -avz --delete -e "sshpass -p '$SSH_PASSWORD' ssh -o StrictHostKeyChecking=no" \
            "$source_dir/" "$SSH_USER@$BACKUP_APP_IP:$target_dir/" >> "$LOG_FILE" 2>&1
    else
        rsync -avz --delete -e "ssh -o StrictHostKeyChecking=no" \
            "$source_dir/" "$SSH_USER@$BACKUP_APP_IP:$target_dir/" >> "$LOG_FILE" 2>&1
    fi
    
    if [ $? -eq 0 ]; then
        echo "[$TIMESTAMP] ✅ Синхронизация $source_dir завершена успешно" >> "$LOG_FILE"
    else
        echo "[$TIMESTAMP] ❌ Ошибка синхронизации $source_dir" >> "$LOG_FILE"
    fi
done

echo "[$TIMESTAMP] Завершение синхронизации файлов" >> "$LOG_FILE"
echo "---" >> "$LOG_FILE"
EOF
    
    chmod +x sync_files.sh
    
    # Настройка cron
    CURRENT_DIR=$(pwd)
    crontab -l 2>/dev/null | grep -v "sync_files.sh" | crontab -
    (crontab -l 2>/dev/null; echo "*/5 * * * * cd $CURRENT_DIR && ./sync_files.sh") | crontab -
    
    log_info "Cron задача для sync_files.sh обновлена."
    
    # Первая синхронизация
    ./sync_files.sh && log_info "Первая синхронизация завершена успешно" || log_warn "Ошибка первой синхронизации"
    
    log_info "=== НАСТРОЙКА СИНХРОНИЗАЦИИ ФАЙЛОВ ЗАВЕРШЕНА ==="
}

# Настройка репликации PostgreSQL
setup_replication() {
    clear
    echo "============================================="
    echo "        3. Настройка репликации PostgreSQL  "
    echo "============================================="
    
    if ! load_config; then
        read -p "Нажмите Enter для возврата в меню..."
        return
    fi
    
    log_info "=== НАЧАЛО НАСТРОЙКИ РЕПЛИКАЦИИ POSTGRESQL ==="
    log_info "Основной сервер БД: $PRIMARY_DB_IP"
    log_info "Резервный сервер БД: $BACKUP_DB_IP"
    log_info "Пользователь репликации: $REPL_USER"
    
    log_info "--- Настройка репликации PostgreSQL ---"
    log_warn "Этот шаг включает деструктивные операции на резервном сервере БД!"
    log_warn "Потребуется право на выполнение 'sudo' без пароля для пользователя $SSH_USER"
    
    # Получение информации о версиях PostgreSQL
    log_info "Определение версий PostgreSQL..."
    
    # Проверка статуса PostgreSQL на основном сервере
    local pg_status
    pg_status=$(execute_ssh "$PRIMARY_DB_IP" "sudo systemctl is-active postgresql 2>/dev/null || echo 'inactive'")
    
    if [ "$pg_status" != "active" ]; then
        log_error "PostgreSQL не запущен на основном сервере $PRIMARY_DB_IP"
        log_error "Статус: $pg_status"
        read -p "Попытаться запустить PostgreSQL? [y/N]: " start_pg
        if [[ "$start_pg" =~ ^[yY](es)?$ ]]; then
            execute_ssh "$PRIMARY_DB_IP" "sudo systemctl start postgresql"
            sleep 3
            pg_status=$(execute_ssh "$PRIMARY_DB_IP" "sudo systemctl is-active postgresql 2>/dev/null || echo 'inactive'")
            if [ "$pg_status" != "active" ]; then
                log_error "Не удалось запустить PostgreSQL"
                return 1
            fi
        else
            return 1
        fi
    fi
    
    # Основной сервер
    local primary_pg_version
    primary_pg_version=$(execute_ssh "$PRIMARY_DB_IP" "sudo -u postgres bash -c 'export PGPASSWORD=\"$PRIMARY_DB_SUPER_PASS\"; psql -U \"$PRIMARY_DB_SUPER_USER\" -t -c \"SHOW server_version;\"' | tr -d ' '")
    
    if [ -z "$primary_pg_version" ]; then
        log_error "Не удалось определить версию PostgreSQL на основном сервере $PRIMARY_DB_IP"
        log_error "Проверьте, что PostgreSQL запущен и пароль корректный"
        return 1
    fi
    
    local primary_pg_major_version=$(echo "$primary_pg_version" | cut -d '.' -f 1)
    
    # Получение путей к конфигурационным файлам
    local primary_conf_path
    primary_conf_path=$(execute_ssh "$PRIMARY_DB_IP" "sudo -u postgres bash -c 'export PGPASSWORD=\"$PRIMARY_DB_SUPER_PASS\"; psql -U \"$PRIMARY_DB_SUPER_USER\" -t -c \"SHOW config_file;\"' | tr -d '[:space:]'")
    
    local primary_hba_path
    primary_hba_path=$(execute_ssh "$PRIMARY_DB_IP" "sudo -u postgres bash -c 'export PGPASSWORD=\"$PRIMARY_DB_SUPER_PASS\"; psql -U \"$PRIMARY_DB_SUPER_USER\" -t -c \"SHOW hba_file;\"' | tr -d '[:space:]'")
    
    # Fallback для определения путей, если не удалось получить из PostgreSQL
    if [ -z "$primary_conf_path" ]; then
        primary_conf_path=$(execute_ssh "$PRIMARY_DB_IP" "find /etc/postgresql -name 'postgresql.conf' 2>/dev/null | head -n 1")
        if [ -z "$primary_conf_path" ]; then
            primary_conf_path="/etc/postgresql/$primary_pg_major_version/main/postgresql.conf"
        fi
    fi
    
    if [ -z "$primary_hba_path" ]; then
        primary_hba_path=$(execute_ssh "$PRIMARY_DB_IP" "find /etc/postgresql -name 'pg_hba.conf' 2>/dev/null | head -n 1")
        if [ -z "$primary_hba_path" ]; then
            primary_hba_path="/etc/postgresql/$primary_pg_major_version/main/pg_hba.conf"
        fi
    fi
    
    log_info "Основной сервер: PG v$primary_pg_version, Config: $primary_conf_path, HBA: $primary_hba_path"
    
    # Проверка существования конфигурационных файлов
    if ! execute_ssh "$PRIMARY_DB_IP" "sudo test -f $primary_conf_path"; then
        log_error "Файл конфигурации $primary_conf_path не найден"
        return 1
    fi
    
    if ! execute_ssh "$PRIMARY_DB_IP" "sudo test -f $primary_hba_path"; then
        log_error "Файл pg_hba.conf $primary_hba_path не найден"
        return 1
    fi
    
    # Резервный сервер
    local backup_pg_version
    backup_pg_version=$(execute_ssh "$BACKUP_DB_IP" "sudo -u postgres bash -c 'export PGPASSWORD=\"$PRIMARY_DB_SUPER_PASS\"; psql -U \"$PRIMARY_DB_SUPER_USER\" -t -c \"SHOW server_version;\"' | tr -d ' '")
    
    local backup_pg_major_version
    if [ -n "$backup_pg_version" ]; then
        backup_pg_major_version=$(echo "$backup_pg_version" | cut -d '.' -f 1)
        log_info "Резервный сервер: найдена PG v$backup_pg_version"
    else
        log_warn "Не удалось определить версию PostgreSQL на резервном сервере"
        log_warn "Возможно, он не установлен, не запущен или требует пароль"
        
        # Проверяем, установлен ли PostgreSQL
        local pg_installed
        pg_installed=$(execute_ssh "$BACKUP_DB_IP" "which psql 2>/dev/null || echo 'not_found'")
        
        if [ "$pg_installed" = "not_found" ]; then
            log_warn "PostgreSQL не установлен на резервном сервере"
            backup_pg_major_version="0"
        else
            read -p "Выберите действие: [1] Попробовать ввести пароль, [2] Продолжить с переустановкой [2]: " choice
            choice=${choice:-2}
            
            if [ "$choice" == "1" ]; then
                read -sp "Введите пароль для суперпользователя ($PRIMARY_DB_SUPER_USER) на резервном сервере: " temp_backup_pass
                echo
                backup_pg_version=$(execute_ssh "$BACKUP_DB_IP" "sudo -u postgres bash -c 'export PGPASSWORD=\"$temp_backup_pass\"; psql -U \"$PRIMARY_DB_SUPER_USER\" -t -c \"SHOW server_version;\"' | tr -d ' '")
                if [ -n "$backup_pg_version" ]; then
                    backup_pg_major_version=$(echo "$backup_pg_version" | cut -d '.' -f 1)
                    log_info "Успешно! Резервный сервер: найдена PG v$backup_pg_version"
                else
                    log_error "Подключиться с паролем не удалось. Продолжаем с переустановкой"
                    backup_pg_major_version="0"
                fi
            else
                log_info "Выбрана переустановка. Продолжаем..."
                backup_pg_major_version="0"
            fi
        fi
    fi
    
    # Проверка совместимости версий
    if [ "$primary_pg_major_version" != "$backup_pg_major_version" ]; then
        log_warn "Версии PostgreSQL не совпадают или резервный не установлен"
        log_warn "Будет произведена переустановка и очистка данных на резервном сервере!"
        read -p "Вы уверены, что хотите продолжить? [y/N]: " confirmation
        [[ ! "$confirmation" =~ ^[yY](es)?$ ]] && { log_error "Операция прервана пользователем."; return 1; }
    fi
    
    # Настройка основного сервера
    log_info "Настройка основного сервера..."
    
    # Создание пользователя репликации
    log_info "Создание пользователя для репликации..."
    execute_ssh "$PRIMARY_DB_IP" "sudo -u postgres bash -c 'export PGPASSWORD=\"$PRIMARY_DB_SUPER_PASS\"; psql -U \"$PRIMARY_DB_SUPER_USER\" -c \"CREATE ROLE $REPL_USER WITH LOGIN REPLICATION PASSWORD '\''$REPL_PASS'\'';\"' 2>/dev/null || true"
    
    # Редактирование postgresql.conf
    log_info "Редактирование postgresql.conf..."
    execute_ssh "$PRIMARY_DB_IP" "sudo sed -i 's/^#*listen_addresses = .*/listen_addresses = '\''*'\''/' $primary_conf_path"
    execute_ssh "$PRIMARY_DB_IP" "sudo sed -i 's/^#*wal_level = .*/wal_level = replica/' $primary_conf_path"
    execute_ssh "$PRIMARY_DB_IP" "sudo sed -i 's/^#*max_wal_senders = .*/max_wal_senders = 10/' $primary_conf_path"
    execute_ssh "$PRIMARY_DB_IP" "sudo sed -i 's/^#*wal_keep_size = .*/wal_keep_size = 512/' $primary_conf_path"
    
    # Редактирование pg_hba.conf
    log_info "Редактирование pg_hba.conf..."
    local hba_entry="host    replication     $REPL_USER    $BACKUP_DB_IP/32          md5"
    execute_ssh "$PRIMARY_DB_IP" "grep -qF '$hba_entry' $primary_hba_path || echo '$hba_entry' | sudo tee -a $primary_hba_path"
    
    # Перезапуск PostgreSQL
    log_info "Перезапуск PostgreSQL на основном сервере..."
    execute_ssh "$PRIMARY_DB_IP" "sudo systemctl restart postgresql"
    
    log_info "Основной сервер успешно настроен."
    
    # Настройка резервного сервера
    log_info "Настройка резервного сервера..."
    
    local backup_data_dir="/var/lib/postgresql/$primary_pg_major_version/main"
    
    # Переустановка PostgreSQL если нужно
    if [ "$primary_pg_major_version" != "$backup_pg_major_version" ]; then
        log_info "=== НАЧАЛО ПЕРЕУСТАНОВКИ POSTGRESQL ==="
        log_info "Удаление старой версии PostgreSQL и установка postgresql-$primary_pg_major_version..."
        
        if ! install_postgresql "$primary_pg_major_version" "$BACKUP_DB_IP"; then
            log_error "Ошибка установки PostgreSQL на резервном сервере"
            return 1
        fi
        
        log_info "=== ПЕРЕУСТАНОВКА POSTGRESQL ЗАВЕРШЕНА ==="
    fi
    
    # Остановка и очистка
    log_info "Остановка и очистка каталога данных..."
    local backup_pg_service_name
    backup_pg_service_name=$(execute_ssh "$BACKUP_DB_IP" "systemctl list-units --type=service | grep 'postgresql@' | sed 's/ .*//' | head -n 1")
    [ -z "$backup_pg_service_name" ] && backup_pg_service_name="postgresql"
    
    execute_ssh "$BACKUP_DB_IP" "sudo systemctl stop $backup_pg_service_name"
    execute_ssh "$BACKUP_DB_IP" "sudo -u postgres rm -rf $backup_data_dir/*"
    
    # Запуск pg_basebackup
    log_info "Запуск pg_basebackup..."
    execute_ssh "$BACKUP_DB_IP" "sudo -u postgres bash -c 'export PGPASSWORD=\"$REPL_PASS\"; pg_basebackup -h $PRIMARY_DB_IP -p $PRIMARY_DB_PORT -D $backup_data_dir -U $REPL_USER -v -P -R --wal-method=stream'"
    
    # Запуск PostgreSQL
    log_info "Запуск PostgreSQL на резервном сервере..."
    execute_ssh "$BACKUP_DB_IP" "sudo systemctl start $backup_pg_service_name"
    
    log_info "${GREEN}Настройка репликации PostgreSQL успешно завершена!${NC}"
    log_info "=== НАСТРОЙКА РЕПЛИКАЦИИ POSTGRESQL ЗАВЕРШЕНА ==="
}

# Установка PostgreSQL на резервном сервере
install_postgresql() {
    local version="$1"
    local host="$2"
    
    log_info "=== НАЧАЛО УСТАНОВКИ POSTGRESQL $version НА $host ==="
    
    # Определение дистрибутива
    local distro
    distro=$(execute_ssh "$host" "lsb_release -si 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo 'unknown'")
    
    log_info "Определен дистрибутив: $distro"
    
    # Остановка существующего PostgreSQL
    log_info "Остановка существующего PostgreSQL..."
    execute_ssh "$host" "sudo systemctl stop postgresql || sudo systemctl stop postgresql@* || true"
    log_info "PostgreSQL остановлен"
    
    # Удаление старой версии
    log_info "Удаление старой версии PostgreSQL..."
    execute_ssh "$host" "sudo apt-get -y purge 'postgresql*'"
    log_info "Удаление завершено"
    
    execute_ssh "$host" "sudo apt-get -y autoremove"
    log_info "Автоудаление завершено"
    
    # Очистка старых репозиториев PostgreSQL
    log_info "Очистка старых репозиториев PostgreSQL..."
    execute_ssh "$host" "sudo rm -f /etc/apt/sources.list.d/pgdg.list /etc/apt/sources.list.d/pgdg.sources"
    log_info "Старые репозитории удалены"
    
    # Дополнительная очистка от предыдущих неудачных установок
    log_info "Дополнительная очистка от предыдущих установок..."
    execute_ssh "$host" "sudo rm -rf /etc/apt/keyrings/postgresql.gpg /etc/apt/keyrings/postgresql.gpg~"
    execute_ssh "$host" "sudo apt-get clean"
    execute_ssh "$host" "sudo apt-get autoclean"
    log_info "Дополнительная очистка завершена"
    
    # Добавление официального репозитория PostgreSQL
    log_info "Добавление официального репозитория PostgreSQL..."
    
    if [ "$distro" = "ubuntu" ] || [ "$distro" = "debian" ]; then
        # Установка зависимостей для репозитория
        log_info "Установка зависимостей для репозитория..."
        execute_ssh "$host" "sudo apt-get update && sudo apt-get install -y wget gnupg2 lsb-release"
        log_info "Зависимости установлены"
        
        # Добавление ключа репозитория (исправленный метод)
        log_info "Добавление GPG ключа репозитория..."
        execute_ssh "$host" "sudo mkdir -p /etc/apt/keyrings"
        execute_ssh "$host" "wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo gpg --dearmor --batch --yes -o /etc/apt/keyrings/postgresql.gpg"
        execute_ssh "$host" "sudo chmod a+r /etc/apt/keyrings/postgresql.gpg"
        log_info "GPG ключ добавлен"
        
        # Добавление репозитория (новый формат)
        log_info "Добавление репозитория PostgreSQL..."
        local codename
        codename=$(execute_ssh "$host" "lsb_release -cs")
        log_info "Кодовое имя дистрибутива: $codename"
        execute_ssh "$host" "echo \"deb [signed-by=/etc/apt/keyrings/postgresql.gpg] http://apt.postgresql.org/pub/repos/apt/ $codename-pgdg main\" | sudo tee /etc/apt/sources.list.d/pgdg.list"
        log_info "Репозиторий добавлен"
        
        # Обновление списка пакетов
        log_info "Обновление списка пакетов..."
        execute_ssh "$host" "sudo apt-get update"
        log_info "Список пакетов обновлен"
        
        # Установка PostgreSQL (только основной пакет)
        log_info "Установка PostgreSQL $version из официального репозитория..."
        execute_ssh "$host" "sudo apt-get install -y postgresql-$version"
        log_info "PostgreSQL $version установлен"
        
        # Попытка установки contrib пакета (опционально)
        log_info "Попытка установки contrib пакета..."
        execute_ssh "$host" "sudo apt-get install -y postgresql-$version-contrib" || log_warn "Contrib пакет недоступен, продолжаем без него"
        
        # Проверка, что PostgreSQL установился
        log_info "Проверка установки PostgreSQL..."
        local pg_installed_check
        pg_installed_check=$(execute_ssh "$host" "dpkg -l | grep postgresql-$version || echo 'not_installed'")
        
        if [[ "$pg_installed_check" == *"not_installed"* ]]; then
            log_error "PostgreSQL $version не установился!"
            log_error "Попытка установки из стандартных репозиториев..."
            execute_ssh "$host" "sudo apt-get install -y postgresql postgresql-contrib"
        else
            log_info "PostgreSQL $version успешно установлен"
        fi
        
    elif [ "$distro" = "centos" ] || [ "$distro" = "rhel" ] || [ "$distro" = "rocky" ] || [ "$distro" = "almalinux" ]; then
        # Для CentOS/RHEL/Rocky/AlmaLinux
        log_info "Установка PostgreSQL $version для CentOS/RHEL..."
        
        # Установка репозитория
        execute_ssh "$host" "sudo yum install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-\$(rpm -E %rhel)/x86_64/pgdg-redhat-repo-latest.noarch.rpm"
        
        # Установка PostgreSQL
        execute_ssh "$host" "sudo yum install -y postgresql$version-server postgresql$version-contrib"
        
        # Инициализация базы данных
        execute_ssh "$host" "sudo /usr/pgsql-$version/bin/postgresql-$version-setup initdb"
        
    else
        # Fallback для неизвестных дистрибутивов
        log_warn "Неизвестный дистрибутив $distro, попытка установки из стандартных репозиториев..."
        execute_ssh "$host" "sudo apt-get update && sudo apt-get install -y postgresql postgresql-contrib"
    fi
    
    # Определение правильного имени сервиса
    log_info "Определение имени сервиса PostgreSQL..."
    local pg_service_name
    pg_service_name=$(execute_ssh "$host" "systemctl list-units --type=service | grep 'postgresql@' | sed 's/ .*//' | head -n 1")
    
    if [ -z "$pg_service_name" ]; then
        pg_service_name="postgresql"
    fi
    
    log_info "Имя сервиса PostgreSQL: $pg_service_name"
    
    # Запуск PostgreSQL
    log_info "Запуск PostgreSQL..."
    execute_ssh "$host" "sudo systemctl enable $pg_service_name"
    execute_ssh "$host" "sudo systemctl start $pg_service_name"
    log_info "PostgreSQL запущен"
    
    # Проверка статуса сервиса
    log_info "Проверка статуса сервиса PostgreSQL..."
    local service_status
    service_status=$(execute_ssh "$host" "sudo systemctl is-active $pg_service_name")
    log_info "Статус сервиса: $service_status"
    
    # Проверка установки
    log_info "Проверка установки PostgreSQL..."
    local installed_version
    installed_version=$(execute_ssh "$host" "sudo -u postgres bash -c 'export PGPASSWORD=\"$PRIMARY_DB_SUPER_PASS\"; psql -U \"$PRIMARY_DB_SUPER_USER\" -t -c \"SHOW server_version;\"' | tr -d ' ' 2>/dev/null")
    
    if [ -n "$installed_version" ]; then
        log_info "PostgreSQL успешно установлен: v$installed_version"
        log_info "=== УСТАНОВКА POSTGRESQL ЗАВЕРШЕНА УСПЕШНО ==="
        return 0
    else
        log_error "Ошибка установки PostgreSQL"
        log_error "Проверяем, установлен ли psql..."
        local psql_path
        psql_path=$(execute_ssh "$host" "which psql 2>/dev/null || echo 'not_found'")
        log_error "Путь к psql: $psql_path"
        
        log_error "Проверяем статус сервиса..."
        local final_status
        final_status=$(execute_ssh "$host" "sudo systemctl status $pg_service_name --no-pager -l")
        log_error "Статус сервиса: $final_status"
        
        log_error "=== УСТАНОВКА POSTGRESQL ЗАВЕРШЕНА С ОШИБКОЙ ==="
        return 1
    fi
}

# Проверка состояния
check_status() {
    clear
    echo "============================================="
    echo "        2. Проверка состояния               "
    echo "============================================="
    
    if ! load_config; then
        read -p "Нажмите Enter для возврата в меню..."
        return
    fi
    
    echo "📊 Проверка состояния резервирования..."
    
    # Проверка cron
    echo "⏰ Проверка cron задачи для sync_files.sh..."
    if crontab -l 2>/dev/null | grep -q "sync_files.sh"; then
        echo "✅ Cron задача для sync_files.sh активна"
        crontab -l | grep "sync_files.sh"
    else
        echo "❌ Cron задача для sync_files.sh не найдена"
    fi
    
    # Проверка лога
    echo "📄 Последние записи лога синхронизации файлов:"
    if [ -f "$LOG_FILE" ]; then
        tail -10 "$LOG_FILE"
    else
        echo "❌ Лог файл $LOG_FILE не найден"
    fi
    
    # Сравнение количества файлов
    echo "📁 Сравнение количества файлов в директориях:"
    for i in "${!SYNC_DIRS_SOURCE[@]}"; do
        source_dir="${SYNC_DIRS_SOURCE[$i]}"
        target_dir="${SYNC_DIRS_TARGET[$i]}"
        
        if [ -d "$source_dir" ]; then
            source_count=$(find "$source_dir" -type f | wc -l)
        else
            source_count=0
        fi
        
        echo "📂 $source_dir: $source_count файлов"
        
        if check_ssh_access "$BACKUP_APP_IP"; then
            backup_count=$(execute_ssh "$BACKUP_APP_IP" "find $target_dir -type f 2>/dev/null | wc -l")
            echo "📂 $BACKUP_APP_IP:$target_dir: $backup_count файлов"
            
            if [ "$source_count" = "$backup_count" ]; then
                echo "✅ Количество файлов совпадает"
            else
                echo "⚠️ Количество файлов не совпадает"
            fi
        else
            echo "❌ Не удается подключиться к резервному серверу приложений"
        fi
        echo
    done
    
    # Проверка статуса репликации PostgreSQL
    echo "🗄️ Проверка статуса репликации PostgreSQL..."
    
    # Основной сервер
    if check_ssh_access "$PRIMARY_DB_IP"; then
        echo "📊 Основной сервер $PRIMARY_DB_IP:"
        if execute_ssh "$PRIMARY_DB_IP" "sudo systemctl is-active postgresql" | grep -q "active"; then
            echo "✅ PostgreSQL активен"
            
            # Проверка подключений репликации
            local repl_connections
            repl_connections=$(execute_ssh "$PRIMARY_DB_IP" "sudo -u postgres bash -c 'export PGPASSWORD=\"$PRIMARY_DB_SUPER_PASS\"; psql -U \"$PRIMARY_DB_SUPER_USER\" -c \"SELECT count(*) FROM pg_stat_activity WHERE application_name = '\''walreceiver'\'';\" -t' | tr -d ' '")
            echo "🔗 Активных подключений для репликации: $repl_connections"
        else
            echo "❌ PostgreSQL не активен"
        fi
    else
        echo "❌ Не удается подключиться к основному серверу БД"
    fi
    
    # Резервный сервер
    if check_ssh_access "$BACKUP_DB_IP"; then
        echo "📊 Резервный сервер $BACKUP_DB_IP:"
        if execute_ssh "$BACKUP_DB_IP" "sudo systemctl is-active postgresql" | grep -q "active"; then
            echo "✅ PostgreSQL активен"
            
            if execute_ssh "$BACKUP_DB_IP" "sudo test -f /var/lib/postgresql/*/main/standby.signal"; then
                echo "🔄 Работает в режиме репликации (standby)"
                
                # Информация о репликации
                local lag_info
                lag_info=$(execute_ssh "$BACKUP_DB_IP" "sudo -u postgres bash -c 'export PGPASSWORD=\"$PRIMARY_DB_SUPER_PASS\"; psql -U \"$PRIMARY_DB_SUPER_USER\" -c \"SELECT pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn(), pg_is_in_recovery();\" -t'" 2>/dev/null)
                if [ $? -eq 0 ]; then
                    echo "📊 Информация о репликации:"
                    echo "$lag_info"
                fi
            else
                echo "⚠️ Не работает в режиме репликации"
            fi
        else
            echo "❌ PostgreSQL не активен"
        fi
    else
        echo "❌ Не удается подключиться к резервному серверу БД"
    fi
    
    echo "✅ Проверка состояния завершена"
    read -p "Нажмите Enter для возврата в меню..."
}

# Остановка резервирования
stop_replication() {
    clear
    echo "============================================="
    echo "        4. Остановка резервирования         "
    echo "============================================="
    
    if ! load_config; then
        read -p "Нажмите Enter для возврата в меню..."
        return
    fi
    
    echo "🛑 Остановка резервирования..."
    
    # Удаление cron задачи
    crontab -l 2>/dev/null | grep -v "sync_files.sh" | crontab -
    log_info "Cron задача для sync_files.sh удалена."
    
    # Остановка репликации на резервном сервере
    if check_ssh_access "$BACKUP_DB_IP"; then
        execute_ssh "$BACKUP_DB_IP" "sudo systemctl stop postgresql"
        execute_ssh "$BACKUP_DB_IP" "sudo rm -f /var/lib/postgresql/*/main/recovery.conf /var/lib/postgresql/*/main/standby.signal"
        execute_ssh "$BACKUP_DB_IP" "sudo systemctl start postgresql"
    fi
    
    # Очистка конфигурации на основном сервере
    if check_ssh_access "$PRIMARY_DB_IP"; then
        execute_ssh "$PRIMARY_DB_IP" "sudo -u postgres bash -c 'export PGPASSWORD=\"$PRIMARY_DB_SUPER_PASS\"; psql -U \"$PRIMARY_DB_SUPER_USER\" -c \"DROP USER IF EXISTS $REPL_USER;\"'"
        
        local conf_path
        conf_path=$(execute_ssh "$PRIMARY_DB_IP" "sudo -u postgres bash -c 'export PGPASSWORD=\"$PRIMARY_DB_SUPER_PASS\"; psql -U \"$PRIMARY_DB_SUPER_USER\" -t -c \"SHOW config_file;\"' | tr -d '[:space:]'")
        
        local hba_path
        hba_path=$(execute_ssh "$PRIMARY_DB_IP" "sudo -u postgres bash -c 'export PGPASSWORD=\"$PRIMARY_DB_SUPER_PASS\"; psql -U \"$PRIMARY_DB_SUPER_USER\" -t -c \"SHOW hba_file;\"' | tr -d '[:space:]'")
        
        execute_ssh "$PRIMARY_DB_IP" "sudo sed -i '/^wal_level/d' $conf_path"
        execute_ssh "$PRIMARY_DB_IP" "sudo sed -i '/^max_wal_senders/d' $conf_path"
        execute_ssh "$PRIMARY_DB_IP" "sudo sed -i '/^wal_keep_size/d' $conf_path"
        execute_ssh "$PRIMARY_DB_IP" "sudo sed -i '/^host.*replication/d' $hba_path"
        execute_ssh "$PRIMARY_DB_IP" "sudo systemctl restart postgresql"
    fi
    
    log_info "Резервирование остановлено. Резервный сервер теперь основной. Синхронизация файлов остановлена."
    read -p "Нажмите Enter для возврата в меню..."
}

# Главное меню
main() {
    while true; do
        clear
        echo "========================================="
        echo "    Скрипт управления резервированием    "
        echo "========================================="
        echo "1. Настроить параметры резервирования"
        echo "2. Проверить состояние"
        echo "3. Запустить резервирование"
        echo "4. Остановить резервирование"
        echo "5. Выход"
        echo "-----------------------------------------"
        read -p "Выберите опцию [1-5]: " choice
        
        case $choice in
            1) configure_params ;;
            2) check_status ;;
            3) load_config && setup_file_sync && setup_replication ;;
            4) stop_replication ;;
            5) log_info "Выход."; exit 0 ;;
            *) log_warn "Неверный выбор. Пожалуйста, попробуйте снова."; sleep 2 ;;
        esac
    done
}

# Запуск
main 

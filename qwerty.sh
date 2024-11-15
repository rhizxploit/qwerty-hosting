#!/bin/bash

# Skrip Installer Pterodactyl Panel dengan pengecekan error dan perbaikan otomatis

echo "=========================="
echo "Installer Pterodactyl Panel dengan Sistem Pengecekan"
echo "=========================="

# Fungsi untuk memeriksa status layanan
check_service_status() {
    SERVICE=$1
    if ! systemctl is-active --quiet "$SERVICE"; then
        echo "Layanan $SERVICE tidak berjalan. Memulai ulang layanan..."
        sudo systemctl restart "$SERVICE" || { echo "Gagal memulai layanan $SERVICE."; exit 1; }
    else
        echo "Layanan $SERVICE berjalan dengan baik."
    fi
}

# Fungsi untuk memeriksa apakah sebuah paket terinstal
check_package_installed() {
    PACKAGE=$1
    if ! dpkg -l | grep -q "$PACKAGE"; then
        echo "Paket $PACKAGE tidak ditemukan. Menginstal $PACKAGE..."
        sudo apt install -y "$PACKAGE" || { echo "Gagal menginstal paket $PACKAGE."; exit 1; }
    else
        echo "Paket $PACKAGE sudah terinstal."
    fi
}

# Fungsi untuk memeriksa file konfigurasi Nginx
check_nginx_config() {
    if ! sudo nginx -t; then
        echo "Konfigurasi Nginx error. Memperbaiki konfigurasi..."
        sudo systemctl reload nginx || { echo "Gagal me-reload Nginx."; exit 1; }
    else
        echo "Konfigurasi Nginx valid."
    fi
}

# Meminta input domain dari pengguna
read -p "Masukkan domain untuk panel (contoh: panel.example.com): " DOMAIN

if [[ -z "$DOMAIN" ]]; then
    echo "Domain tidak boleh kosong. Jalankan ulang skrip dan masukkan domain yang valid."
    exit 1
fi

# Update dan upgrade sistem
echo "1. Update dan upgrade sistem..."
sudo apt update && sudo apt upgrade -y || { echo "Gagal memperbarui sistem."; exit 1; }

# Periksa dan instal dependensi dasar
echo "2. Memeriksa dependensi dasar..."
DEPENDENCIES=(software-properties-common curl apt-transport-https ca-certificates unzip git nginx)
for PACKAGE in "${DEPENDENCIES[@]}"; do
    check_package_installed "$PACKAGE"
done

# Periksa dan instal PHP, MariaDB, dan Composer
echo "3. Memeriksa PHP, MariaDB, dan Composer..."
PHP_DEPENDENCIES=(php8.2 php8.2-cli php8.2-fpm php8.2-mbstring php8.2-xml php8.2-curl php8.2-tokenizer php8.2-common php8.2-mysql mariadb-server composer)
for PACKAGE in "${PHP_DEPENDENCIES[@]}"; do
    check_package_installed "$PACKAGE"
done

# Periksa layanan MariaDB
echo "4. Memeriksa layanan MariaDB..."
check_service_status mariadb

# Konfigurasi MariaDB jika diperlukan
if ! sudo mysql -u root -e "USE pterodactyl;" &>/dev/null; then
    echo "Database belum dikonfigurasi. Membuat database dan user..."
    sudo mysql -u root -e "CREATE DATABASE IF NOT EXISTS pterodactyl;"
    sudo mysql -u root -e "CREATE USER IF NOT EXISTS 'ptero'@'localhost' IDENTIFIED BY 'password_kuat';"
    sudo mysql -u root -e "GRANT ALL PRIVILEGES ON pterodactyl.* TO 'ptero'@'localhost' WITH GRANT OPTION;"
    sudo mysql -u root -e "FLUSH PRIVILEGES;"
else
    echo "Database dan user MariaDB sudah ada."
fi

# Unduh dan konfigurasi Pterodactyl Panel
echo "5. Memeriksa instalasi Pterodactyl Panel..."
if [[ ! -d "/var/www/pterodactyl" ]]; then
    echo "Pterodactyl Panel belum terinstal. Menginstal panel..."
    sudo mkdir -p /var/www/pterodactyl || { echo "Gagal membuat direktori Pterodactyl."; exit 1; }
    sudo chown -R "$USER:$USER" /var/www/pterodactyl
    cd /var/www/pterodactyl
    curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz || { echo "Gagal mengunduh panel."; exit 1; }
    tar -xzvf panel.tar.gz || { echo "Gagal mengekstrak panel."; exit 1; }
    chmod -R 755 storage/* bootstrap/cache/

    echo "Menginstal dependensi PHP untuk panel..."
    composer install --no-dev --optimize-autoloader || { echo "Gagal menginstal dependensi PHP."; exit 1; }

    echo "Mengonfigurasi panel..."
    cp .env.example .env
    php artisan key:generate --force
    php artisan migrate --seed --force
    sudo chown -R www-data:www-data /var/www/pterodactyl
else
    echo "Pterodactyl Panel sudah terinstal."
fi

# Periksa konfigurasi Nginx
echo "6. Mengonfigurasi Nginx..."
if [[ ! -f "/etc/nginx/sites-available/pterodactyl.conf" ]]; then
    echo "File konfigurasi Nginx belum ada. Membuat konfigurasi baru..."
    cat <<EOF | sudo tee /etc/nginx/sites-available/pterodactyl.conf
server {
    listen 80;
    server_name $DOMAIN;
    root /var/www/pterodactyl/public;

    index index.php;

    location / {
        try_files \$uri \$uri/ /index.php;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php8.2-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF
    sudo ln -s /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/
else
    echo "File konfigurasi Nginx sudah ada."
fi

# Periksa validitas konfigurasi Nginx
check_nginx_config

# Restart Nginx untuk menerapkan perubahan
sudo systemctl restart nginx || { echo "Gagal merestart Nginx."; exit 1; }

# Membuat akun admin pertama kali untuk login
echo "7. Membuat akun admin pertama kali untuk login ke Pterodactyl Panel..."
read -p "Masukkan email admin: " ADMIN_EMAIL
read -p "Masukkan username admin: " ADMIN_USERNAME
read -s -p "Masukkan password admin: " ADMIN_PASSWORD
echo

# Menjalankan perintah untuk membuat akun admin
cd /var/www/pterodactyl
php artisan p:user:make --email="$ADMIN_EMAIL" --username="$ADMIN_USERNAME" --password="$ADMIN_PASSWORD" --admin || { echo "Gagal membuat akun admin."; exit 1; }

# Selesai
echo "=========================="
echo "Instalasi dan Pengecekan Pterodactyl selesai!"
echo "Akses panel di http://$DOMAIN"
echo "=========================="

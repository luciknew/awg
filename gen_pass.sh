#!/bin/bash
read -sp "Введи пароль: " password
echo
hash=$(python3 -c "import bcrypt; print(bcrypt.hashpw(b'$password', bcrypt.gensalt(rounds=12)).decode())")
escaped_hash=$(echo "$hash" | sed 's/\$/\$\$/g')
echo
echo "Хеш для docker-compose.yml:"
echo "$escaped_hash"
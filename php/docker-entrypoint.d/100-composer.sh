#! /bin/bash

ssh-keyscan -t rsa bitbucket.org >> ~/.ssh/known_hosts;
ssh-keyscan -t rsa github.com >> ~/.ssh/known_hosts;
git config --global --add safe.directory /opt/project/vendor/inlearno/book;
rm -rf ./www/desktop/vendor/react-navi
composer update;
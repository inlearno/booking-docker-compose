#! /bin/bash


ssh-keyscan -t rsa bitbucket.org >> ~/.ssh/known_hosts
composer update

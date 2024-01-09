#! /bin/bash

COMPOSER_BUILD=/var/composer.update

if [ ! -e $COMPOSER_BUILD ] || [ $COMPOSER_BUILD -ot ./composer.json ]; then
  ssh-keyscan -t rsa bitbucket.org >> ~/.ssh/known_hosts;
  composer update;
  touch $COMPOSER_BUILD;
fi;
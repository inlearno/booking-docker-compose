FROM percona/percona-server:5.7
LABEL maintainer="KidsState" email="support_navi@inlearno.com"
LABEL Description="PERCONA 5.7 for Navigator Project"
LABEL Version="1.0.7"

# It is manipulation with system files
USER root

# Setting timezone
RUN ln -snf /usr/share/zoneinfo/Europe/Moscow /etc/localtime && echo "Europe/Moscow" > /etc/timezone

# Copy own mysqld.cnf file
COPY ./conf/mysqld.cnf /etc/percona-server.conf.d/mysqld.cnf
RUN chown mysql:mysql /etc/percona-server.conf.d/mysqld.cnf

COPY ./conf/docker-entrypoint.sh /docker-entrypoint.sh

# Install additional software
RUN microdnf install nano -y && microdnf clean all
# Run daemon as mysql user
USER mysql


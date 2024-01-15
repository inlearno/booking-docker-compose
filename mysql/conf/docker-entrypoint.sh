#!/bin/bash
set -eo pipefail
shopt -s nullglob

# if command starts with an option, prepend mysqld
if [ "${1:0:1}" = '-' ]; then
	set -- mysqld "$@"
fi

# skip setup if they want an option that stops mysqld
wantHelp=
for arg; do
	case "$arg" in
		-'?'|--help|--print-defaults|-V|--version)
			wantHelp=1
			break
			;;
	esac
done

# usage: file_env VAR [DEFAULT]
#    ie: file_env 'XYZ_DB_PASSWORD' 'example'
# (will allow for "$XYZ_DB_PASSWORD_FILE" to fill in the value of
#  "$XYZ_DB_PASSWORD" from a file, especially for Docker's secrets feature)
file_env() {
	local var="$1"
	local fileVar="${var}_FILE"
	local def="${2:-}"
	if [ "${!var:-}" ] && [ "${!fileVar:-}" ]; then
		echo >&2 "error: both $var and $fileVar are set (but are exclusive)"
		exit 1
	fi
	local val="$def"
	if [ "${!var:-}" ]; then
		val="${!var}"
	elif [ "${!fileVar:-}" ]; then
		val="$(< "${!fileVar}")"
	fi
	export "$var"="$val"
	unset "$fileVar"
}

# usage: process_init_file FILENAME MYSQLCOMMAND...
#    ie: process_init_file foo.sh mysql -uroot
# (process a single initializer file, based on its extension. we define this
# function here, so that initializer scripts (*.sh) can use the same logic,
# potentially recursively, or override the logic used in subsequent calls)
process_init_file() {
	local f="$1"; shift
	local mysql=( "$@" )

	case "$f" in
		*.sh)     echo "$0: running $f"; . "$f" ;;
		*.sql)    echo "$0: running $f"; "${mysql[@]}" < "$f"; echo ;;
		*.sql.gz) echo "$0: running $f"; gunzip -c "$f" | "${mysql[@]}"; echo ;;
		*)        echo "$0: ignoring $f" ;;
	esac
	echo
}

_check_config() {
	toRun=( "$@" --verbose --help )
	if ! errors="$("${toRun[@]}" 2>&1 >/dev/null)"; then
		cat >&2 <<-EOM

			ERROR: mysqld failed while attempting to check config
			command was: "${toRun[*]}"

			$errors
		EOM
		exit 1
	fi
}

# Fetch value from server config
# We use mysqld --verbose --help instead of my_print_defaults because the
# latter only show values present in config files, and not server defaults
_get_config() {
	local conf="$1"; shift
	"$@" --verbose --help --log-bin-index="$(mktemp -u)" 2>/dev/null \
		| awk '$1 == "'"$conf"'" && /^[^ \t]/ { sub(/^[^ \t]+[ \t]+/, ""); print; exit }'
	# match "datadir      /some/path with/spaces in/it here" but not "--xyz=abc\n     datadir (xyz)"
}

if [ "$1" = 'mysqld' -a -z "$wantHelp" ]; then
	# still need to check config, container may have started with --user
	_check_config "$@"

	if [ -n "$INIT_TOKUDB" ]; then
		export LD_PRELOAD=/usr/lib64/libjemalloc.so.1
	fi
	# Get config
	DATADIR="$(_get_config 'datadir' "$@")"

	if [ ! -d "$DATADIR/mysql" ]; then
		file_env 'MYSQL_ROOT_PASSWORD'
		if [ -z "$MYSQL_ROOT_PASSWORD" -a -z "$MYSQL_ALLOW_EMPTY_PASSWORD" -a -z "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
			echo >&2 'error: database is uninitialized and password option is not specified '
			echo >&2 '  You need to specify one of MYSQL_ROOT_PASSWORD, MYSQL_ALLOW_EMPTY_PASSWORD and MYSQL_RANDOM_ROOT_PASSWORD'
			exit 1
		fi

		mkdir -p "$DATADIR"

		echo 'Initializing database'
		"$@" --initialize-insecure --skip-ssl
		echo 'Database initialized'

		if command -v mysql_ssl_rsa_setup > /dev/null && [ ! -e "$DATADIR/server-key.pem" ]; then
			# https://github.com/mysql/mysql-server/blob/23032807537d8dd8ee4ec1c4d40f0633cd4e12f9/packaging/deb-in/extra/mysql-systemd-start#L81-L84
			echo 'Initializing certificates'
			mysql_ssl_rsa_setup --datadir="$DATADIR"
			echo 'Certificates initialized'
		fi

		SOCKET="$(_get_config 'socket' "$@")"
		"$@" --skip-networking --socket="${SOCKET}" &
		pid="$!"

		mysql=( mysql --protocol=socket -uroot -hlocalhost --socket="${SOCKET}" --password="" )

		for i in {120..0}; do
			if echo 'SELECT 1' | "${mysql[@]}" &> /dev/null; then
				break
			fi
			echo 'MySQL init process in progress...'
			sleep 1
		done
		if [ "$i" = 0 ]; then
			echo >&2 'MySQL init process failed.'
			exit 1
		fi

		if [ -z "$MYSQL_INITDB_SKIP_TZINFO" ]; then
			# sed is for https://bugs.mysql.com/bug.php?id=20545
			mysql_tzinfo_to_sql /usr/share/zoneinfo | sed 's/Local time zone must be set--see zic manual page/FCTY/' | "${mysql[@]}" mysql
		fi

		# install TokuDB engine
		if [ -n "$INIT_TOKUDB" ]; then
			ps-admin --docker --enable-tokudb -u root -p $MYSQL_ROOT_PASSWORD
		fi
		if [ -n "$INIT_ROCKSDB" ]; then
			ps-admin --docker --enable-rocksdb -u root -p $MYSQL_ROOT_PASSWORD
		fi

		if [ ! -z "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
			MYSQL_ROOT_PASSWORD="$(pwmake 128)"
			echo "GENERATED ROOT PASSWORD: $MYSQL_ROOT_PASSWORD"
		fi

		rootCreate=
		# default root to listen for connections from anywhere
		file_env 'MYSQL_ROOT_HOST' '%'
		if [ ! -z "$MYSQL_ROOT_HOST" -a "$MYSQL_ROOT_HOST" != 'localhost' ]; then
			# no, we don't care if read finds a terminating character in this heredoc
			# https://unix.stackexchange.com/questions/265149/why-is-set-o-errexit-breaking-this-read-heredoc-expression/265151#265151
			read -r -d '' rootCreate <<-EOSQL || true
				CREATE USER 'root'@'${MYSQL_ROOT_HOST}' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}' ;
				GRANT ALL ON *.* TO 'root'@'${MYSQL_ROOT_HOST}' WITH GRANT OPTION ;
			EOSQL
		fi

		"${mysql[@]}" <<-EOSQL
			-- What's done in this file shouldn't be replicated
			--  or products like mysql-fabric won't work
			SET @@SESSION.SQL_LOG_BIN=0;

			DELETE FROM mysql.user WHERE user NOT IN ('mysql.sys', 'mysqlxsys', 'root') OR host NOT IN ('localhost') ;
			SET PASSWORD FOR 'root'@'localhost'=PASSWORD('${MYSQL_ROOT_PASSWORD}') ;
			GRANT ALL ON *.* TO 'root'@'localhost' WITH GRANT OPTION ;
			${rootCreate}
			DROP DATABASE IF EXISTS test ;
			FLUSH PRIVILEGES ;
		EOSQL

		if [ ! -z "$MYSQL_ROOT_PASSWORD" ]; then
			mysql+=( -p"${MYSQL_ROOT_PASSWORD}" )
		fi

		file_env 'MYSQL_DATABASE'
		if [ "$MYSQL_DATABASE" ]; then
			echo "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\` ;" | "${mysql[@]}"
			mysql+=( "$MYSQL_DATABASE" )
		fi

		file_env 'MYSQL_USER'
		file_env 'MYSQL_PASSWORD'
		if [ "$MYSQL_USER" -a "$MYSQL_PASSWORD" ]; then
			echo "CREATE USER '$MYSQL_USER'@'%' IDENTIFIED BY '$MYSQL_PASSWORD' ;" | "${mysql[@]}"

			if [ "$MYSQL_DATABASE" ]; then
				echo "GRANT ALL ON \`$MYSQL_DATABASE\`.* TO '$MYSQL_USER'@'%' ;" | "${mysql[@]}"
			fi

			echo 'FLUSH PRIVILEGES ;' | "${mysql[@]}"
		fi

		echo
		ls /docker-entrypoint-initdb.d/ > /dev/null
		for f in /docker-entrypoint-initdb.d/*; do
			process_init_file "$f" "${mysql[@]}"
		done

		if [ ! -z "$MYSQL_ONETIME_PASSWORD" ]; then
			"${mysql[@]}" <<-EOSQL
				ALTER USER 'root'@'%' PASSWORD EXPIRE;
			EOSQL
		fi
		if ! kill -s TERM "$pid" || ! wait "$pid"; then
			echo >&2 'MySQL init process failed.'
			exit 1
		fi

		echo
		echo 'MySQL init process done. Ready for start up.'
		echo
	fi

	# exit when MYSQL_INIT_ONLY environment variable is set to avoid starting mysqld
	if [ ! -z "$MYSQL_INIT_ONLY" ]; then
		echo 'Initialization complete, now exiting!'
		exit 0
	fi

    # START CUSTOM SELFCONFIGURATION SECTION
    if [ -n "${ENV_INNODB_BUFFER_POOL_SIZE}" ] ; then
		echo "Config ENV detected: ENV_INNODB_BUFFER_POOL_SIZE: ${ENV_INNODB_BUFFER_POOL_SIZE}. Config updated."
		sed -i "s/innodb_buffer_pool_size         = 1024/innodb_buffer_pool_size         = ${ENV_INNODB_BUFFER_POOL_SIZE}/" /etc/percona-server.conf.d/mysqld.cnf
    fi

    if [ ! -z "$REPLICATION_ID" ]; then
        echo "Config ENV detected: REPLICATION_ID = ${REPLICATION_ID}. Adding replication settings to config..."
        cat <<EOF> /etc/percona-server.conf.d/replication.cnf
# === replication ===
# Process binlogs 3 days, shrink up to 1Gb and rotate only 3 logs.
[mysqld]
expire_logs_days                = 3
#binlog-space-limit              = 3
max_binlog_size                 = 1024M
max_binlog_files                = 5
server-id                       = ${REPLICATION_ID}

# To be able to conect to db via Mysql Workbench/SequelPro/other UI tools
# It is not recommended to use the mysql_native_password authentication plugin for new installations that require high password security.
default_authentication_plugin     = mysql_native_password

# Binary log file name (for data recovery after possible mysql server crash).
log_bin                           = mysql-binlog.log

# The MySQL Server system variables described in this section are used to monitor and control Global Transaction Identifiers (GTIDs).
enforce_gtid_consistency          = ON

# Controls whether GTID based logging is enabled and what type of transactions the logs can contain/# enforce_gtid_consistency must be true before you can set gtid_mode=ON.
gtid_mode                         = ON

# Whether updates received by a replica from a replication source server should be logged to the replica's own binary log.
log_slave_updates                 = ON

# When binlog_checksum is disabled (value NONE),
# the server verifies that it is writing only complete events to the binary log
# by writing and checking the event length (rather than a checksum) for each event.
binlog_checksum                   = NONE

# The setting of this variable determines whether the replica records source metadata, consisting of status and connection information,
# to an InnoDB table in the mysql system database, or to a file in the data directory.
# default value - TABLE
master_info_repository            = TABLE

# The setting of this variable determines whether the replica server logs its position in the relay logs
# to an InnoDB table in the mysql system database, or to a file in the data directory.
# default value - TABLE
relay_log_info_repository         = TABLE

# This option tells the server to load the named plugins at startup.
# plugin-load-add                   = group_replication.so
# In our case this is group_replication plugin. If this enable - Percona 57-44 got error: 
#   Function 'group_replication' already exists
#   Couldn't load plugin named 'group_replication' with soname 'group_replication.so'.
#   Plugin group_replication reported: 'Extraction of transaction write sets requires an hash algorithm configuration. 
#   Please, double check that the parameter transaction-write-set-extraction is set to a valid algorithm.'

# Load this plugin in case when server bin logs are too far away / removed.
# So group replication makes a clone of the current master (dump) and continue replication as default.
# 5.7 has no contains this plugin. But 8.0 contains it. State here for future migration 5.7->8.0
# plugin-load-add                   = mysql_clone.so
# If enabled, this variable enables automatic relay log recovery immediately following server startup.

# The recovery process creates a new relay log file, initializes the SQL thread position to this new relay log,
# and initializes the I/O thread to the SQL thread position.
relay_log_recovery                = ON

## Can be multiple. If it had not declared then all databases will be synced.
#binlog-do-db=DATABASE
## List ignored databases. This databases will excluded from replication.
#binlog-ignore-db=information_schema
#binlog-ignore-db=mysql
##--- end replication section ---
EOF
    else
        echo "REPLICATION_ID ENV is not detected. Skipping any modifications..."

    fi
    # END CUSTOM SELFCONFIGURATION SECTION

fi

exec "$@"

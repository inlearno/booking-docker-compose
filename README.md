### Booking docker compose for local development

- Rename .env.sample to .env
- Change environment variables in .env if needed
  - PROJECT_DIR - path to directory with project repository
  - PORT - exposed project port 
  - MYSQL_ROOT_PASSWORD - mysql password
  - MYSQL_DATABASE - mysql database name
  - MYSQL_EXPOSE_PORT - mysql port

| You  should change config take mysql params from env

- Run update.sh script
- After all services started and completed (for check use docker compose ps) visit http://localhost:2600
COMPOSE := docker compose
EXEC    := $(COMPOSE) exec -T db

.PHONY: all up migrate info seed test queries psql down reset

all: up migrate seed test   ## Start Postgres, migrate, seed and test

up:                          ## Start PostgreSQL
	$(COMPOSE) up -d --wait db

migrate:                     ## Apply Flyway migrations
	$(COMPOSE) run --rm flyway migrate

info:                        ## Show migration status
	$(COMPOSE) run --rm flyway info

seed:                        ## Load reference + synthetic data
	$(EXEC) sh scripts/seed.sh

test:                        ## Run the SQL test suite
	$(EXEC) sh scripts/test.sh

queries:                     ## Run all business-question queries
	$(EXEC) sh scripts/run_queries.sh

psql:                        ## Open an interactive psql shell
	$(COMPOSE) exec db psql

down:                        ## Stop containers (keeps data)
	$(COMPOSE) down

reset:                       ## Drop all data and rebuild from scratch
	$(COMPOSE) down -v
	$(MAKE) all

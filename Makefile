SHELL := /bin/bash
.PHONY: up down build logs seed test restart-api restart-web

up:            ## start stack
	docker compose up -d

down:          ## stop stack
	docker compose down

build:         ## rebuild API (no-cache)
	docker compose build --no-cache api

logs:          ## API logs
	docker compose logs -f api

seed:          ## demo seed if available
	- docker compose exec -T api python /app/seed_demo.py

test:          ## run PDF public tests
	docker compose exec -T api pytest -q /app/tests/test_invoice_public_pdf.py

restart-api:
	docker compose restart api

restart-web:
	docker compose restart web

-- Fake sanitized dump for tests (fake data only).
CREATE TABLE customers (id integer PRIMARY KEY, email text NOT NULL, name text NOT NULL);
INSERT INTO customers VALUES (1, 'u0000000001@example.invalid', 'Fake Person One'), (2, 'u0000000002@example.invalid', 'Fake Person Two');

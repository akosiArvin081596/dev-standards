-- Fake sanitized MySQL dump for tests (fake data only).
CREATE TABLE customers (id int PRIMARY KEY, email varchar(100) NOT NULL);
INSERT INTO customers VALUES (1, 'u0000000001@example.invalid'), (2, 'u0000000002@example.invalid'), (3, 'u0000000003@example.invalid');

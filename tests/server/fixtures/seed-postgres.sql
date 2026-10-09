-- Fake production data for the server container tests. Real-LOOKING, not real: every person,
-- address, email and number here is made up for the anonymization tests.
CREATE TABLE customers (
  id serial PRIMARY KEY,
  full_name text NOT NULL,
  email text NOT NULL UNIQUE,
  phone text,
  address text,
  birth_date date,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE users (
  id serial PRIMARY KEY,
  email text NOT NULL UNIQUE,
  display_name text,
  password_hash text NOT NULL,
  remember_token text
);
CREATE TABLE orders (
  id serial PRIMARY KEY,
  customer_email text NOT NULL REFERENCES customers (email),
  shipping_city text,
  total numeric(10, 2) NOT NULL
);
CREATE TABLE feature_flags (
  name text PRIMARY KEY,
  enabled boolean NOT NULL DEFAULT false,
  updated_at timestamp NOT NULL DEFAULT (now() AT TIME ZONE 'UTC'),
  updated_by text
);
INSERT INTO customers (full_name, email, phone, address, birth_date) VALUES
  ('Juan Dela Cruz', 'jdc.fixture.0142@gmail.com', '+639171234567', '123 Rizal Avenue, Sampaloc, Manila', '1986-04-12'),
  ('Maria Clara Santos', 'mcsantos.fixture77@yahoo.com', '09181234567', '45 Mabini Street, Quezon City', '1990-11-03'),
  ('Jose Protacio Mercado', 'jpmercado.fixture@outlook.com', '+63 917 555 0101', '9 Bonifacio Drive, Cebu City', '1979-06-19'),
  ('Gabriela Silang Reyes', 'gsreyes.fixture.31@gmail.com', '0917-888-2468', '77 Luna Street, Davao City', '2001-02-28'),
  ('Andres Bautista', 'abautista.fixture9@hotmail.com', '+639209876543', 'Unit 5, 88 Ayala Avenue, Makati', '1995-08-08'),
  ('Corazon Aquino Lim', 'calim.fixture.55@gmail.com', '09271112233', '12 Session Road, Baguio City', '1983-12-25'),
  ('Emilio Navarro', 'enavarro.fixture@company-mail.ph', '+639351234000', '3 Osmena Boulevard, Cebu City', '1972-01-15'),
  ('Teresa Magbanua Cruz', 'tmcruz.fixture.08@gmail.com', NULL, NULL, NULL);
INSERT INTO users (email, display_name, password_hash, remember_token) VALUES
  ('admin.fixture@gmail.com', 'Ramon', '$2y$10$abcdefghijklmnopqrstuvABCDEFGHIJKLMNOPQRSTUVWXYZ01234', 'tok_4f9a1c2b7e6d5a3f'),
  ('staff.fixture22@yahoo.com', 'Lorna', '$2y$10$zyxwvutsrqponmlkjihgfeZYXWVUTSRQPONMLKJIHGFEDCBA98765', 'tok_9e8d7c6b5a4f3e2d'),
  ('jdc.fixture.0142@gmail.com', 'Juan', '$2y$10$mnopqrstuvwxyzabcdefghMNOPQRSTUVWXYZABCDEFGHIJKL55555', NULL);
INSERT INTO orders (customer_email, shipping_city, total) VALUES
  ('jdc.fixture.0142@gmail.com', 'Manila', 1250.00),
  ('jdc.fixture.0142@gmail.com', 'Manila', 310.50),
  ('mcsantos.fixture77@yahoo.com', 'Quezon City', 999.99),
  ('gsreyes.fixture.31@gmail.com', 'Davao City', 45.00),
  ('calim.fixture.55@gmail.com', 'Baguio City', 780.25),
  ('enavarro.fixture@company-mail.ph', 'Cebu City', 15000.00);
INSERT INTO feature_flags (name, enabled, updated_by) VALUES ('existing-flag', true, 'seed');

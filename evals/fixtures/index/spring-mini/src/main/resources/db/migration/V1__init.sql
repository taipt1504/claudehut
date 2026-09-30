-- create table ignored_in_comment (id int);

CREATE TABLE orders (id uuid primary key);
CREATE TABLE IF NOT EXISTS customers (id uuid primary key);

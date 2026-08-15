-- V1: Baseline demo schema.
-- Non-production/test schema only. clientes/pedidos are example tables used
-- to demonstrate Flyway versioned + repeatable migrations; they are not
-- production data models.

CREATE TABLE clientes (
    id INT PRIMARY KEY AUTO_INCREMENT,
    nombre VARCHAR(100) NOT NULL,
    email VARCHAR(150) NOT NULL,
    creado_en DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE pedidos (
    id INT PRIMARY KEY AUTO_INCREMENT,
    cliente_id INT NOT NULL,
    estado VARCHAR(20) NOT NULL DEFAULT 'pendiente',
    creado_en DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_pedidos_cliente
        FOREIGN KEY (cliente_id) REFERENCES clientes(id)
);

INSERT INTO clientes (nombre, email) VALUES
    ('Ana Torres', 'ana.torres@example.com'),
    ('Luis Perez', 'luis.perez@example.com');

INSERT INTO pedidos (cliente_id, estado) VALUES
    (1, 'pendiente'),
    (2, 'enviado');

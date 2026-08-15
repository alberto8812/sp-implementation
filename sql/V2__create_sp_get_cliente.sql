-- V2: Versioned example stored procedure.
-- Stand-in demo SP only (not a real production SP). Once applied, this file
-- must NOT be edited — Flyway validates versioned migrations by checksum and
-- will fail on any post-apply change. That immutability is deliberate demo
-- contrast against the repeatable SP in R__sp_actualizar_pedido.sql.

DELIMITER //

CREATE PROCEDURE sp_get_cliente(IN p_id INT)
BEGIN
    SELECT id, nombre, email, creado_en
    FROM clientes
    WHERE id = p_id;
END //

DELIMITER ;

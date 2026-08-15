-- R__: Repeatable example stored procedure.
-- Stand-in demo SP only (not a real production SP). MySQL 8 has no
-- `CREATE OR REPLACE PROCEDURE`, so this repeatable migration always drops
-- and recreates the procedure. Editing this file changes its checksum;
-- Flyway will re-apply it on the next `migrate` run and record a new
-- flyway_schema_history row — this is the live-demo edit target.

DROP PROCEDURE IF EXISTS sp_actualizar_pedido;

DELIMITER //

CREATE PROCEDURE sp_actualizar_pedido(IN p_pedido_id INT, IN p_estado VARCHAR(20))
BEGIN
    IF p_estado NOT IN ('pendiente', 'procesando', 'enviado', 'entregado', 'cancelado') THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Estado inválido para pedido';
    END IF;

    IF (SELECT estado FROM pedidos WHERE id = p_pedido_id) = 'entregado' AND p_estado = 'cancelado' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'No se puede cancelar un pedido ya entregado';
    END IF;

    UPDATE pedidos
    SET estado = p_estado
    WHERE id = p_pedido_id;
END //

DELIMITER ;

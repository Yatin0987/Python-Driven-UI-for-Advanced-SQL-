
-- =============================================
-- PostgreSQL Inventory Management Script
-- =============================================

-- ---------------------------------------------
-- Initial Data Checks
-- ---------------------------------------------
SELECT * FROM products;
SELECT * FROM reorders;
SELECT * FROM shipments;
SELECT * FROM stock_entries;
SELECT * FROM suppliers;

-- WARNING: This will delete your products table. 
-- Only run this if you intend to reset your data.
-- DROP TABLE IF EXISTS products;

-- ---------------------------------------------
-- Analytical Queries
-- ---------------------------------------------

-- 1. Total Suppliers
SELECT count(*) AS total_suppliers FROM suppliers;

-- 2. Total Products
SELECT count(*) AS total_products FROM products;

-- 3. Total unique categories
SELECT count(distinct category) AS total_categories FROM products;

-- 4. Total sales value made in last 3 months (quantity * price)
SELECT ROUND(SUM(ABS(se.change_quantity) * p.price), 2) AS total_sales_value_in_last_3_months
FROM stock_entries AS se 
JOIN products p ON p.product_id = se.product_id
WHERE se.change_type = 'Sale'
  AND se.entry_date >= (SELECT MAX(entry_date) - INTERVAL '3 months' FROM stock_entries);

-- 5. Total restock value made in last 3 months
SELECT ROUND(SUM(ABS(se.change_quantity) * p.price), 2) AS total_restock_value_in_last_3_months
FROM stock_entries AS se 
JOIN products p ON p.product_id = se.product_id
WHERE se.change_type = 'Restock'
  AND se.entry_date >= (SELECT MAX(entry_date) - INTERVAL '3 months' FROM stock_entries);

-- 6. Products needing restock but not yet ordered (Pending)
SELECT count(*) 
FROM products AS p  
WHERE p.stock_quantity < p.reorder_level
  AND product_id NOT IN (
    SELECT DISTINCT product_id FROM reorders WHERE status = 'Pending'
);

-- 7. Suppliers and their contact details
SELECT supplier_name, contact_name, email, phone FROM suppliers;

-- 8. Product with their suppliers and current stock
SELECT p.product_name, s.supplier_name, p.stock_quantity, p.reorder_level
FROM products AS p 
JOIN suppliers s ON p.supplier_id = s.supplier_id
ORDER BY p.product_name ASC;

-- 9. Product needing reorder
SELECT product_id, product_name, stock_quantity, reorder_level 
FROM products 
WHERE stock_quantity < reorder_level;

-- ---------------------------------------------
-- Stored Procedure: Add New Product
-- ---------------------------------------------

ALTER TABLE shipments RENAME COLUMN quantity_received TO quantity;
CREATE OR REPLACE PROCEDURE AddNewProductManualID(
   p_name varchar(255),
   p_category  varchar(100),
   p_price decimal(10,2),
   p_stock int,
   p_reorder int,
   p_supplier int
)
LANGUAGE plpgsql
AS $$
DECLARE
  new_prod_id int;
  new_shipment_id int;
  new_entry_id int;
BEGIN
  -- Generate product id (Using COALESCE to handle empty tables)
  SELECT COALESCE(MAX(product_id), 0) + 1 INTO new_prod_id FROM products;
  
  INSERT INTO products(product_id, product_name, category, price, stock_quantity, reorder_level, supplier_id)
  VALUES(new_prod_id, p_name, p_category, p_price, p_stock, p_reorder, p_supplier);
  
  -- Generate shipment id
  SELECT COALESCE(MAX(shipment_id), 0) + 1 INTO new_shipment_id FROM shipments;
  
  INSERT INTO shipments (shipment_id, product_id, supplier_id, quantity, shipment_date)
  VALUES(new_shipment_id, new_prod_id, p_supplier, p_stock, CURRENT_DATE);
  
  -- Generate stock entry id
  SELECT COALESCE(MAX(entry_id), 0) + 1 INTO new_entry_id FROM stock_entries;
  
  INSERT INTO stock_entries(entry_id, product_id, change_quantity, change_type, entry_date)
  VALUES (new_entry_id, new_prod_id, p_stock, 'Restock', CURRENT_DATE);

  COMMIT;
END;
$$;


DROP TRIGGER IF EXISTS <quantity_recei
> ON shipments;



ALTER TABLE shipments RENAME COLUMN quantity TO quantity_received;









-- 10. Call the procedure to add a test product
CALL AddNewProductManualID('Smart Watch', 'Electronics', 99.99, 100, 25, 5);

-- Verification Selects
SELECT * FROM products WHERE product_name = 'Bettles';
SELECT * FROM shipments WHERE product_id = 202;
SELECT * FROM stock_entries WHERE product_id = 202;

-- ---------------------------------------------
-- View: Product History
-- ---------------------------------------------
-- 11. Product History View [finding shipment, sales, purchase]
CREATE OR REPLACE VIEW product_inventory_history AS 
SELECT 
    pih.product_id,
    pih.record_type,
    pih.record_date,
    pih.Quantity,
    pih.change_type,
    pr.supplier_id
FROM 
(
    SELECT 
        product_id,
        'Shipment' AS record_type,
        shipment_date AS record_date,
        quantity_received AS Quantity,
        NULL::varchar AS change_type -- Cast NULL to match union column type
    FROM shipments

    UNION ALL

    SELECT 
        product_id,
        'Stock Entry' AS record_type,
        entry_date AS record_date,
        change_quantity AS quantity,
        change_type
    FROM stock_entries
) pih
JOIN products pr ON pr.product_id = pih.product_id;

-- Test View
SELECT * FROM product_inventory_history
WHERE product_id = 123
ORDER BY record_date DESC;

-- ---------------------------------------------
-- Reorder Logic
-- ---------------------------------------------

-- 12. Place a reorder manually
INSERT INTO reorders(reorder_id, product_id, reorder_quantity, reorder_date, status)
SELECT COALESCE(MAX(reorder_id), 0) + 1, 101, 200, CURRENT_DATE, 'ordered' FROM reorders;

-- Check status
SELECT * FROM stock_entries;
SELECT * FROM shipments;
SELECT * FROM reorders;
SELECT * FROM products;

-- ---------------------------------------------
-- Stored Procedure: Receive Reorder
-- ---------------------------------------------
-- 13. Receive reorder (Updates stock, shipments, and reorder status)
CREATE OR REPLACE PROCEDURE MarkReorderAsReceived(in_reorder_id int)
LANGUAGE plpgsql
AS $$
DECLARE
    prod_id int;
    qty int;
    sup_id int;
    new_shipment_id int;
    new_entry_id int;
BEGIN
    -- Get product_id and quantity from reorders
    SELECT Product_id, reorder_quantity 
    INTO prod_id, qty
    FROM reorders
    WHERE reorder_id = in_reorder_id;

    -- Get supplier_id from Products
    SELECT supplier_id
    INTO sup_id 
    FROM products 
    WHERE product_id = prod_id;

    -- Update reorder table
    UPDATE reorders 
    SET status = 'Received'
    WHERE reorder_id = in_reorder_id;

    -- Update quantity in product table
    UPDATE products 
    SET stock_quantity = stock_quantity + qty
    WHERE product_id = prod_id;

    -- Insert record into shipment table
    SELECT COALESCE(MAX(shipment_id), 0) + 1 INTO new_shipment_id FROM shipments;
    
    INSERT INTO shipments(shipment_id, product_id, supplier_id, quantity_received, shipment_date)
    VALUES (new_shipment_id, prod_id, sup_id, qty, CURRENT_DATE);

    -- Insert record into Restock 
    SELECT COALESCE(MAX(entry_id), 0) + 1 INTO new_entry_id FROM stock_entries;
    
    INSERT INTO stock_entries(entry_id, product_id, change_quantity, change_type, entry_date)
    VALUES(new_entry_id, prod_id, qty, 'Restock', CURRENT_DATE);

    COMMIT;
END;
$$;

-- Call the procedure
CALL MarkReorderAsReceived(2);

-- ---------------------------------------------
-- Final Checks
-- ---------------------------------------------
SELECT * FROM reorders WHERE reorder_id = 13;
SELECT * FROM products WHERE product_name = 'Someone Shirt';
SELECT * FROM reorders WHERE reorder_id = 1;
SELECT * FROM stock_entries WHERE product_id = 164 ORDER BY entry_date DESC;
SELECT * FROM shipments ORDER BY shipment_id DESC;
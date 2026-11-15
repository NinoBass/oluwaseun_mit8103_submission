-- =====================================================================
-- Portfolio 1 - 02_reference_data.sql
-- Lookup data for OjaHub Commerce: states, warehouses, category tree,
-- couriers are plain text in shipment so they are not seeded here.
-- =====================================================================
SET search_path = ojahub, public;

INSERT INTO state_region (state_code, state_name, geo_zone) VALUES
('AB','Abia','South East'),        ('AD','Adamawa','North East'),   ('AK','Akwa Ibom','South South'),
('AN','Anambra','South East'),     ('BA','Bauchi','North East'),    ('BY','Bayelsa','South South'),
('BE','Benue','North Central'),    ('BO','Borno','North East'),     ('CR','Cross River','South South'),
('DE','Delta','South South'),      ('EB','Ebonyi','South East'),    ('ED','Edo','South South'),
('EK','Ekiti','South West'),       ('EN','Enugu','South East'),     ('FC','FCT Abuja','North Central'),
('GO','Gombe','North East'),       ('IM','Imo','South East'),       ('JI','Jigawa','North West'),
('KD','Kaduna','North West'),      ('KN','Kano','North West'),      ('KT','Katsina','North West'),
('KE','Kebbi','North West'),       ('KO','Kogi','North Central'),   ('KW','Kwara','North Central'),
('LA','Lagos','South West'),       ('NA','Nasarawa','North Central'),('NI','Niger','North Central'),
('OG','Ogun','South West'),        ('ON','Ondo','South West'),      ('OS','Osun','South West'),
('OY','Oyo','South West'),         ('PL','Plateau','North Central'),('RI','Rivers','South South'),
('SO','Sokoto','North West'),      ('TA','Taraba','North East'),    ('YO','Yobe','North East'),
('ZA','Zamfara','North West');

INSERT INTO warehouse (warehouse_name, city, state_code) VALUES
('Lagos Fulfilment Centre (Ikeja)', 'Ikeja',         'LA'),
('Abuja Hub (Idu)',                 'Abuja',         'FC'),
('Port Harcourt Hub (Trans-Amadi)', 'Port Harcourt', 'RI'),
('Kano Hub (Sharada)',              'Kano',          'KN');

-- Two-level category tree
INSERT INTO category (category_name) VALUES
('Phones & Tablets'), ('Computing'), ('Electronics'), ('Fashion'),
('Home & Kitchen'), ('Health & Beauty'), ('Groceries'), ('Baby Products');

INSERT INTO category (category_name, parent_category_id)
SELECT c.child, p.category_id
FROM (VALUES
  ('Phones & Tablets','Smartphones'), ('Phones & Tablets','Tablets'), ('Phones & Tablets','Phone Accessories'),
  ('Computing','Laptops'), ('Computing','Computer Accessories'), ('Computing','Storage Devices'),
  ('Electronics','Televisions'), ('Electronics','Audio'), ('Electronics','Power & Solar'),
  ('Fashion','Men''s Clothing'), ('Fashion','Women''s Clothing'), ('Fashion','Footwear'),
  ('Home & Kitchen','Small Appliances'), ('Home & Kitchen','Cookware'), ('Home & Kitchen','Furniture'),
  ('Health & Beauty','Skin Care'), ('Health & Beauty','Hair Care'), ('Health & Beauty','Fragrances'),
  ('Groceries','Beverages'), ('Groceries','Food Cupboard'),
  ('Baby Products','Diapering'), ('Baby Products','Baby Feeding')
) AS c(parent, child)
JOIN category p ON p.category_name = c.parent AND p.parent_category_id IS NULL;

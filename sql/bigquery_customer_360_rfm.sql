-- E-Commerce Customer 360 - BigQuery SQL
-- Source: project documentation

-- ============================================================
-- 1. Raw Dataset Validation
-- Purpose: Check event count, unique users, and number of days.
-- ============================================================
SELECT
  COUNT(*) AS event_count,
  COUNT(DISTINCT user_pseudo_id) AS user_count,
  COUNT(DISTINCT event_date) AS day_count
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`;

-- ============================================================
-- 2. Purchase Validation
-- Purpose: Count purchase events and unique purchasing users.
-- ============================================================
SELECT
  COUNT(*) AS purchase_events,
  COUNT(DISTINCT user_pseudo_id) AS purchasing_users
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE event_name = 'purchase';

-- ============================================================
-- 3. Raw Purchase Diagnostic
-- Purpose: Inspect transaction IDs and raw revenue before cleaning.
-- ============================================================
SELECT
  COUNT(*) AS total_purchase_events,
  COUNTIF(ecommerce.transaction_id IS NOT NULL) AS non_null_transaction_ids,
  COUNT(DISTINCT ecommerce.transaction_id) AS unique_transaction_ids,
  COUNT(DISTINCT user_pseudo_id) AS purchasing_users,
  SUM(ecommerce.purchase_revenue_in_usd) AS raw_total_revenue
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE event_name = 'purchase';

-- ============================================================
-- 4. Clean Transactions
-- Purpose: Remove NULL and '(not set)' transaction IDs and create one clean transaction row.
-- ============================================================
CREATE OR REPLACE TABLE `customer-360-rfm-ltv-analytics.analytics.transactions_clean` AS
SELECT
  user_pseudo_id AS customer_id,
  ecommerce.transaction_id AS transaction_id,
  PARSE_DATE('%Y%m%d', event_date) AS transaction_date,
  SUM(ecommerce.purchase_revenue_in_usd) AS transaction_revenue
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE event_name = 'purchase'
  AND ecommerce.transaction_id IS NOT NULL
  AND ecommerce.transaction_id != '(not set)'
GROUP BY customer_id, transaction_id, transaction_date;

-- ============================================================
-- 5. Customer 360
-- Purpose: Combine customer purchase behavior and website engagement.
-- ============================================================
CREATE OR REPLACE TABLE `customer-360-rfm-ltv-analytics.analytics.customer_360` AS
WITH transaction_summary AS (
  SELECT
    customer_id,
    MIN(transaction_date) AS first_purchase_date,
    MAX(transaction_date) AS last_purchase_date,
    COUNT(DISTINCT transaction_id) AS transaction_count,
    SUM(transaction_revenue) AS total_revenue_usd,
    AVG(transaction_revenue) AS avg_transaction_value
  FROM `customer-360-rfm-ltv-analytics.analytics.transactions_clean`
  GROUP BY customer_id
),
engagement_summary AS (
  SELECT
    user_pseudo_id AS customer_id,
    COUNT(*) AS total_events,
    COUNTIF(event_name = 'view_item') AS product_views,
    COUNTIF(event_name = 'add_to_cart') AS add_to_cart_events,
    COUNTIF(event_name = 'begin_checkout') AS checkout_events,
    COUNTIF(event_name = 'page_view') AS page_views
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  GROUP BY customer_id
)
SELECT
  t.customer_id,
  t.first_purchase_date,
  t.last_purchase_date,
  t.transaction_count,
  t.total_revenue_usd,
  t.avg_transaction_value,
  e.total_events,
  e.product_views,
  e.add_to_cart_events,
  e.checkout_events,
  e.page_views
FROM transaction_summary t
LEFT JOIN engagement_summary e
  ON t.customer_id = e.customer_id;

-- ============================================================
-- 6. RFM Base Table
-- Purpose: Calculate Recency, Frequency and Monetary value, then assign 1–5 scores.
-- ============================================================
CREATE OR REPLACE TABLE `customer-360-rfm-ltv-analytics.analytics.customer_rfm` AS
WITH base AS (
  SELECT
    customer_id,
    DATE_DIFF(
      (SELECT MAX(transaction_date)
       FROM `customer-360-rfm-ltv-analytics.analytics.transactions_clean`),
      MAX(transaction_date), DAY
    ) AS recency_days,
    COUNT(DISTINCT transaction_id) AS frequency,
    SUM(transaction_revenue) AS monetary
  FROM `customer-360-rfm-ltv-analytics.analytics.transactions_clean`
  GROUP BY customer_id
)
SELECT
  *,
  NTILE(5) OVER (ORDER BY recency_days DESC) AS recency_score,
  NTILE(5) OVER (ORDER BY frequency) AS frequency_score,
  NTILE(5) OVER (ORDER BY monetary) AS monetary_score
FROM base;

-- ============================================================
-- 7. RFM Segmentation
-- Purpose: Convert RFM scores into business-friendly customer segments.
-- ============================================================
CREATE OR REPLACE TABLE `customer-360-rfm-ltv-analytics.analytics.customer_rfm_segments` AS
SELECT
  *,
  CASE
    WHEN recency_score >= 4 AND frequency_score >= 4 AND monetary_score >= 4
      THEN 'Champions'
    WHEN recency_score >= 3 AND frequency_score >= 3 AND monetary_score >= 3
      THEN 'Loyal Customers'
    WHEN recency_score >= 4 AND frequency_score <= 2
      THEN 'Potential Loyalists'
    WHEN recency_score <= 2 AND frequency_score >= 3 AND monetary_score >= 3
      THEN 'High Value At Risk'
    WHEN recency_score <= 2 AND frequency_score <= 2
      THEN 'Hibernating / Lost'
    WHEN recency_score <= 3 AND monetary_score >= 3
      THEN 'At Risk'
    ELSE 'Other'
  END AS customer_segment
FROM `customer-360-rfm-ltv-analytics.analytics.customer_rfm`;

-- ============================================================
-- 8. Observed Customer LTV
-- Purpose: Calculate historical customer value and purchase-rate metrics.
-- ============================================================
CREATE OR REPLACE TABLE `customer-360-rfm-ltv-analytics.analytics.customer_ltv` AS
SELECT
  customer_id,
  MIN(transaction_date) AS first_purchase_date,
  MAX(transaction_date) AS last_purchase_date,
  COUNT(DISTINCT transaction_id) AS transaction_count,
  SUM(transaction_revenue) AS total_revenue_usd,
  AVG(transaction_revenue) AS avg_transaction_value,
  DATE_DIFF(MAX(transaction_date), MIN(transaction_date), DAY) AS customer_lifespan_days,
  SAFE_DIVIDE(
    COUNT(DISTINCT transaction_id),
    NULLIF(DATE_DIFF(MAX(transaction_date), MIN(transaction_date), DAY), 0)
  ) AS purchase_frequency_per_day,
  SAFE_DIVIDE(
    SUM(transaction_revenue),
    DATE_DIFF(MAX(transaction_date), MIN(transaction_date), DAY) + 1
  ) AS revenue_per_active_day
FROM `customer-360-rfm-ltv-analytics.analytics.transactions_clean`
GROUP BY customer_id;

-- ============================================================
-- 9. Cohort Retention
-- Purpose: Group customers by first purchase month and measure later activity.
-- ============================================================
CREATE OR REPLACE TABLE `customer-360-rfm-ltv-analytics.analytics.customer_cohort_retention` AS
WITH first_purchase AS (
  SELECT customer_id, DATE_TRUNC(MIN(transaction_date), MONTH) AS cohort_month
  FROM `customer-360-rfm-ltv-analytics.analytics.transactions_clean`
  GROUP BY customer_id
),
activity AS (
  SELECT DISTINCT customer_id, DATE_TRUNC(transaction_date, MONTH) AS activity_month
  FROM `customer-360-rfm-ltv-analytics.analytics.transactions_clean`
),
cohort_activity AS (
  SELECT
    f.cohort_month,
    a.activity_month,
    DATE_DIFF(a.activity_month, f.cohort_month, MONTH) AS month_number,
    COUNT(DISTINCT a.customer_id) AS active_customers
  FROM first_purchase f
  JOIN activity a USING (customer_id)
  GROUP BY f.cohort_month, a.activity_month, month_number
),
cohort_size AS (
  SELECT cohort_month, COUNT(*) AS cohort_customers
  FROM first_purchase
  GROUP BY cohort_month
)
SELECT
  ca.cohort_month,
  ca.activity_month,
  ca.month_number,
  cs.cohort_customers,
  ca.active_customers,
  SAFE_DIVIDE(ca.active_customers, cs.cohort_customers) AS retention_rate
FROM cohort_activity ca
JOIN cohort_size cs USING (cohort_month)
ORDER BY cohort_month, month_number;

-- ============================================================
-- 1. Raw Dataset Validation
-- Purpose: Check event count, unique users, and number of days.
-- ============================================================
SELECT
  COUNT(*) AS event_count,
  COUNT(DISTINCT user_pseudo_id) AS user_count,
  COUNT(DISTINCT event_date) AS day_count
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`;

-- ============================================================
-- 2. Purchase Validation
-- Purpose: Count purchase events and unique purchasing users.
-- ============================================================
SELECT
  COUNT(*) AS purchase_events,
  COUNT(DISTINCT user_pseudo_id) AS purchasing_users
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE event_name = 'purchase';

-- ============================================================
-- 3. Raw Purchase Diagnostic
-- Purpose: Inspect transaction IDs and raw revenue before cleaning.
-- ============================================================
SELECT
  COUNT(*) AS total_purchase_events,
  COUNTIF(ecommerce.transaction_id IS NOT NULL) AS non_null_transaction_ids,
  COUNT(DISTINCT ecommerce.transaction_id) AS unique_transaction_ids,
  COUNT(DISTINCT user_pseudo_id) AS purchasing_users,
  SUM(ecommerce.purchase_revenue_in_usd) AS raw_total_revenue
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE event_name = 'purchase';

-- ============================================================
-- 4. Clean Transactions
-- Purpose: Remove NULL and '(not set)' transaction IDs and create one clean transaction row.
-- ============================================================
CREATE OR REPLACE TABLE `customer-360-rfm-ltv-analytics.analytics.transactions_clean` AS
SELECT
  user_pseudo_id AS customer_id,
  ecommerce.transaction_id AS transaction_id,
  PARSE_DATE('%Y%m%d', event_date) AS transaction_date,
  SUM(ecommerce.purchase_revenue_in_usd) AS transaction_revenue
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE event_name = 'purchase'
  AND ecommerce.transaction_id IS NOT NULL
  AND ecommerce.transaction_id != '(not set)'
GROUP BY customer_id, transaction_id, transaction_date;

-- ============================================================
-- 5. Customer 360
-- Purpose: Combine customer purchase behavior and website engagement.
-- ============================================================
CREATE OR REPLACE TABLE `customer-360-rfm-ltv-analytics.analytics.customer_360` AS
WITH transaction_summary AS (
  SELECT
    customer_id,
    MIN(transaction_date) AS first_purchase_date,
    MAX(transaction_date) AS last_purchase_date,
    COUNT(DISTINCT transaction_id) AS transaction_count,
    SUM(transaction_revenue) AS total_revenue_usd,
    AVG(transaction_revenue) AS avg_transaction_value
  FROM `customer-360-rfm-ltv-analytics.analytics.transactions_clean`
  GROUP BY customer_id
),
engagement_summary AS (
  SELECT
    user_pseudo_id AS customer_id,
    COUNT(*) AS total_events,
    COUNTIF(event_name = 'view_item') AS product_views,
    COUNTIF(event_name = 'add_to_cart') AS add_to_cart_events,
    COUNTIF(event_name = 'begin_checkout') AS checkout_events,
    COUNTIF(event_name = 'page_view') AS page_views
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  GROUP BY customer_id
)
SELECT
  t.customer_id,
  t.first_purchase_date,
  t.last_purchase_date,
  t.transaction_count,
  t.total_revenue_usd,
  t.avg_transaction_value,
  e.total_events,
  e.product_views,
  e.add_to_cart_events,
  e.checkout_events,
  e.page_views
FROM transaction_summary t
LEFT JOIN engagement_summary e
  ON t.customer_id = e.customer_id;

-- ============================================================
-- 6. RFM Base Table
-- Purpose: Calculate Recency, Frequency and Monetary value, then assign 1–5 scores.
-- ============================================================
CREATE OR REPLACE TABLE `customer-360-rfm-ltv-analytics.analytics.customer_rfm` AS
WITH base AS (
  SELECT
    customer_id,
    DATE_DIFF(
      (SELECT MAX(transaction_date)
       FROM `customer-360-rfm-ltv-analytics.analytics.transactions_clean`),
      MAX(transaction_date), DAY
    ) AS recency_days,
    COUNT(DISTINCT transaction_id) AS frequency,
    SUM(transaction_revenue) AS monetary
  FROM `customer-360-rfm-ltv-analytics.analytics.transactions_clean`
  GROUP BY customer_id
)
SELECT
  *,
  NTILE(5) OVER (ORDER BY recency_days DESC) AS recency_score,
  NTILE(5) OVER (ORDER BY frequency) AS frequency_score,
  NTILE(5) OVER (ORDER BY monetary) AS monetary_score
FROM base;

-- ============================================================
-- 7. RFM Segmentation
-- Purpose: Convert RFM scores into business-friendly customer segments.
-- ============================================================
CREATE OR REPLACE TABLE `customer-360-rfm-ltv-analytics.analytics.customer_rfm_segments` AS
SELECT
  *,
  CASE
    WHEN recency_score >= 4 AND frequency_score >= 4 AND monetary_score >= 4
      THEN 'Champions'
    WHEN recency_score >= 3 AND frequency_score >= 3 AND monetary_score >= 3
      THEN 'Loyal Customers'
    WHEN recency_score >= 4 AND frequency_score <= 2
      THEN 'Potential Loyalists'
    WHEN recency_score <= 2 AND frequency_score >= 3 AND monetary_score >= 3
      THEN 'High Value At Risk'
    WHEN recency_score <= 2 AND frequency_score <= 2
      THEN 'Hibernating / Lost'
    WHEN recency_score <= 3 AND monetary_score >= 3
      THEN 'At Risk'
    ELSE 'Other'
  END AS customer_segment
FROM `customer-360-rfm-ltv-analytics.analytics.customer_rfm`;

-- ============================================================
-- 8. Observed Customer LTV
-- Purpose: Calculate historical customer value and purchase-rate metrics.
-- ============================================================
CREATE OR REPLACE TABLE `customer-360-rfm-ltv-analytics.analytics.customer_ltv` AS
SELECT
  customer_id,
  MIN(transaction_date) AS first_purchase_date,
  MAX(transaction_date) AS last_purchase_date,
  COUNT(DISTINCT transaction_id) AS transaction_count,
  SUM(transaction_revenue) AS total_revenue_usd,
  AVG(transaction_revenue) AS avg_transaction_value,
  DATE_DIFF(MAX(transaction_date), MIN(transaction_date), DAY) AS customer_lifespan_days,
  SAFE_DIVIDE(
    COUNT(DISTINCT transaction_id),
    NULLIF(DATE_DIFF(MAX(transaction_date), MIN(transaction_date), DAY), 0)
  ) AS purchase_frequency_per_day,
  SAFE_DIVIDE(
    SUM(transaction_revenue),
    DATE_DIFF(MAX(transaction_date), MIN(transaction_date), DAY) + 1
  ) AS revenue_per_active_day
FROM `customer-360-rfm-ltv-analytics.analytics.transactions_clean`
GROUP BY customer_id;

-- ============================================================
-- 9. Cohort Retention
-- Purpose: Group customers by first purchase month and measure later activity.
-- ============================================================
CREATE OR REPLACE TABLE `customer-360-rfm-ltv-analytics.analytics.customer_cohort_retention` AS
WITH first_purchase AS (
  SELECT customer_id, DATE_TRUNC(MIN(transaction_date), MONTH) AS cohort_month
  FROM `customer-360-rfm-ltv-analytics.analytics.transactions_clean`
  GROUP BY customer_id
),
activity AS (
  SELECT DISTINCT customer_id, DATE_TRUNC(transaction_date, MONTH) AS activity_month
  FROM `customer-360-rfm-ltv-analytics.analytics.transactions_clean`
),
cohort_activity AS (
  SELECT
    f.cohort_month,
    a.activity_month,
    DATE_DIFF(a.activity_month, f.cohort_month, MONTH) AS month_number,
    COUNT(DISTINCT a.customer_id) AS active_customers
  FROM first_purchase f
  JOIN activity a USING (customer_id)
  GROUP BY f.cohort_month, a.activity_month, month_number
),
cohort_size AS (
  SELECT cohort_month, COUNT(*) AS cohort_customers
  FROM first_purchase
  GROUP BY cohort_month
)
SELECT
  ca.cohort_month,
  ca.activity_month,
  ca.month_number,
  cs.cohort_customers,
  ca.active_customers,
  SAFE_DIVIDE(ca.active_customers, cs.cohort_customers) AS retention_rate
FROM cohort_activity ca
JOIN cohort_size cs USING (cohort_month)
ORDER BY cohort_month, month_number;

-- ============================================================
-- 10. Customer Funnel
-- Purpose: Count customers reaching view, cart, checkout and purchase stages.
-- ============================================================
CREATE OR REPLACE TABLE `customer-360-rfm-ltv-analytics.analytics.customer_funnel` AS
SELECT
  user_pseudo_id AS customer_id,
  COUNTIF(event_name = 'view_item') AS product_views,
  COUNTIF(event_name = 'add_to_cart') AS add_to_cart_events,
  COUNTIF(event_name = 'begin_checkout') AS checkout_events,
  COUNTIF(event_name = 'purchase') AS purchase_events
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
GROUP BY customer_id;

-- ============================================================
-- 11. Funnel Rates
-- Purpose: Calculate conversion between consecutive funnel stages.
-- ============================================================
SELECT
  COUNTIF(product_views > 0) AS view_product_customers,
  COUNTIF(add_to_cart_events > 0) AS add_to_cart_customers,
  COUNTIF(checkout_events > 0) AS checkout_customers,
  COUNTIF(purchase_events > 0) AS purchase_customers
FROM `customer-360-rfm-ltv-analytics.analytics.customer_funnel`;

-- ============================================================
-- 12. Product Analysis
-- Purpose: UNNEST the GA4 items array and summarize products.
-- ============================================================
SELECT
  item.item_id,
  item.item_name,
  COUNTIF(event_name = 'view_item') AS product_views,
  COUNTIF(event_name = 'add_to_cart') AS add_to_cart_events,
  COUNTIF(event_name = 'purchase') AS purchase_events,
  SUM(IF(event_name = 'purchase', item.quantity, 0)) AS units_sold,
  SUM(IF(event_name = 'purchase', item.item_revenue_in_usd, 0)) AS product_revenue
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`,
UNNEST(items) AS item
GROUP BY item.item_id, item.item_name;

-- ============================================================
-- 13. Customer Engagement
-- Purpose: Summarize customer activity across GA4 events.
-- ============================================================
CREATE OR REPLACE TABLE `customer-360-rfm-ltv-analytics.analytics.customer_engagement` AS
SELECT
  user_pseudo_id AS customer_id,
  COUNT(*) AS total_events,
  COUNTIF(event_name = 'view_item') AS product_views,
  COUNTIF(event_name = 'add_to_cart') AS add_to_cart_events,
  COUNTIF(event_name = 'begin_checkout') AS checkout_events,
  COUNTIF(event_name = 'purchase') AS purchase_events,
  COUNTIF(event_name = 'page_view') AS page_views
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
GROUP BY customer_id;

-- ============================================================
-- 14. Customer Risk
-- Purpose: Create simplified risk groups from RFM segments and customer value.
-- ============================================================
CREATE OR REPLACE TABLE `customer-360-rfm-ltv-analytics.analytics.customer_risk` AS
SELECT
  l.customer_id,
  l.total_revenue_usd AS total_ltv,
  r.customer_segment,
  CASE
    WHEN r.customer_segment = 'High Value At Risk' THEN 'High Value At Risk'
    WHEN r.customer_segment = 'At Risk' THEN 'At Risk'
    WHEN r.customer_segment = 'Hibernating / Lost' THEN 'Hibernating / Lost'
    WHEN r.customer_segment = 'Champions' THEN 'Champions'
    WHEN r.customer_segment = 'Loyal Customers' THEN 'Loyal Customers'
    ELSE 'Other'
  END AS risk_segment
FROM `customer-360-rfm-ltv-analytics.analytics.customer_ltv` l
LEFT JOIN `customer-360-rfm-ltv-analytics.analytics.customer_rfm_segments` r
  ON l.customer_id = r.customer_id;

-- ============================================================
-- 15. Revenue at Risk
-- Purpose: Apply predefined scenario factors to customer value.
-- ============================================================
CREATE OR REPLACE TABLE `customer-360-rfm-ltv-analytics.analytics.revenue_at_risk` AS
SELECT
  risk_segment,
  COUNT(DISTINCT customer_id) AS customer_count,
  SUM(total_ltv) AS total_ltv,
  CASE
    WHEN risk_segment = 'High Value At Risk' THEN 0.75
    WHEN risk_segment = 'At Risk' THEN 0.50
    WHEN risk_segment = 'Hibernating / Lost' THEN 0.90
    ELSE 0.00
  END AS risk_factor,
  SUM(total_ltv) *
  CASE
    WHEN risk_segment = 'High Value At Risk' THEN 0.75
    WHEN risk_segment = 'At Risk' THEN 0.50
    WHEN risk_segment = 'Hibernating / Lost' THEN 0.90
    ELSE 0.00
  END AS revenue_at_risk
FROM `customer-360-rfm-ltv-analytics.analytics.customer_risk`
GROUP BY risk_segment;

-- ============================================================
-- 16. ML Churn Features
-- Purpose: Prepare customer features for a 30-day inactivity model.
-- ============================================================
SELECT
  r.customer_id,
  r.recency_days,
  r.frequency,
  r.monetary,
  c.avg_transaction_value,
  c.total_events,
  c.product_views,
  c.add_to_cart_events,
  c.checkout_events,
  c.page_views,
  (c.add_to_cart_events + c.checkout_events + c.purchase_events) AS shopping_events
FROM `customer-360-rfm-ltv-analytics.analytics.customer_rfm` r
JOIN `customer-360-rfm-ltv-analytics.analytics.customer_360` c
  USING (customer_id);

-- ============================================================
-- 17. ML LTV Features
-- Purpose: Prepare historical features and a future revenue target.
-- ============================================================
SELECT
  r.customer_id,
  r.recency_days,
  r.frequency,
  r.monetary AS historical_revenue,
  c.avg_transaction_value,
  c.total_events,
  c.product_views,
  c.add_to_cart_events,
  c.checkout_events,
  c.page_views
FROM `customer-360-rfm-ltv-analytics.analytics.customer_rfm` r
JOIN `customer-360-rfm-ltv-analytics.analytics.customer_360` c
  USING (customer_id);

-- ============================================================
-- 18. Rolling LTV Dataset
-- Purpose: Create 17 daily cutoff snapshots and predict the next 30 days.
-- ============================================================
WITH cutoff_dates AS (
  SELECT cutoff_date
  FROM UNNEST(GENERATE_DATE_ARRAY(
    DATE '2020-12-15', DATE '2020-12-31', INTERVAL 1 DAY
  )) AS cutoff_date
)
SELECT cutoff_date
FROM cutoff_dates
ORDER BY cutoff_date;

-- ============================================================
-- 19. K-Means Feature Table
-- Purpose: Prepare the nine numerical features used for customer clustering.
-- ============================================================
SELECT
  customer_id,
  recency_days,
  frequency,
  monetary AS historical_revenue,
  avg_transaction_value,
  total_events,
  product_views,
  add_to_cart_events,
  checkout_events,
  page_views
FROM `customer-360-rfm-ltv-analytics.analytics.customer_360`;

-- ============================================================
-- 20. Quality Checks
-- Purpose: Run simple checks before Power BI or ML.
-- ============================================================
SELECT
  COUNT(*) AS rows,
  COUNT(DISTINCT customer_id) AS unique_customers,
  COUNTIF(customer_id IS NULL) AS null_customer_ids
FROM `customer-360-rfm-ltv-analytics.analytics.customer_360`;

SELECT
  COUNT(*) AS rows,
  SUM(total_revenue_usd) AS total_revenue,
  MIN(first_purchase_date) AS first_purchase,
  MAX(last_purchase_date) AS last_purchase
FROM `customer-360-rfm-ltv-analytics.analytics.customer_360`;

SELECT
  customer_segment,
  COUNT(*) AS customer_count,
  SUM(monetary) AS revenue
FROM `customer-360-rfm-ltv-analytics.analytics.customer_rfm_segments`
GROUP BY customer_segment
ORDER BY revenue DESC;

-- =====================================================================================
-- Barker & Stonehouse: Opportunities build (run with the query location set to europe-west2)
--
-- Runs top to bottom. Every step is wrapped so that a failure is written to
-- bs_core.build_log and the next step still runs. The dashboard's Data health tab
-- shows the latest result for each step.
--
-- Schedule: daily at about 07:00 (More > Schedule > Create new scheduled query).
-- Store sales must be appended weekly to ometria.store_product_sales
-- (columns: sku, product_title, units_sold, revenue_ex_vat, period_start, period_end).
-- =====================================================================================

DECLARE run_ts TIMESTAMP DEFAULT CURRENT_TIMESTAMP();
DECLARE today  DATE   DEFAULT CURRENT_DATE('Europe/London');
DECLARE yesterday STRING DEFAULT FORMAT_DATE('%Y%m%d', DATE_SUB(CURRENT_DATE('Europe/London'), INTERVAL 1 DAY));
DECLARE d28 STRING DEFAULT FORMAT_DATE('%Y%m%d', DATE_SUB(CURRENT_DATE('Europe/London'), INTERVAL 28 DAY));
DECLARE d60 STRING DEFAULT FORMAT_DATE('%Y%m%d', DATE_SUB(CURRENT_DATE('Europe/London'), INTERVAL 60 DAY));
DECLARE d90 STRING DEFAULT FORMAT_DATE('%Y%m%d', DATE_SUB(CURRENT_DATE('Europe/London'), INTERVAL 90 DAY));

CREATE SCHEMA IF NOT EXISTS `commanding-air-450109-p0.bs_core`  OPTIONS (location = 'europe-west2');
CREATE SCHEMA IF NOT EXISTS `commanding-air-450109-p0.bs_marts` OPTIONS (location = 'europe-west2');

CREATE TABLE IF NOT EXISTS `commanding-air-450109-p0.bs_core.build_log` (
  run_ts TIMESTAMP, step STRING, status STRING, message STRING, finished_at TIMESTAMP
);

CREATE OR REPLACE PROCEDURE `commanding-air-450109-p0.bs_core.log_step`(run_ts TIMESTAMP, step STRING, status STRING, message STRING)
BEGIN
  INSERT INTO `commanding-air-450109-p0.bs_core.build_log` (run_ts, step, status, message, finished_at)
  VALUES (run_ts, step, status, message, CURRENT_TIMESTAMP());
END;

-- ---------- helpers ----------

-- Model key: base SKU (text before the first hyphen), first 8 characters.
CREATE OR REPLACE FUNCTION `commanding-air-450109-p0.bs_core.model_key`(sku STRING)
RETURNS STRING AS (
  UPPER(LEFT(SPLIT(TRIM(sku), '-')[SAFE_OFFSET(0)], 8))
);

CREATE OR REPLACE FUNCTION `commanding-air-450109-p0.bs_core.normalise_url`(url STRING)
RETURNS STRING AS (
  IF(url IS NULL, NULL,
     COALESCE(NULLIF(RTRIM(REGEXP_EXTRACT(LOWER(url), r'^(?:[a-z]+://[^/?#]+)?(/[^?#]*)'), '/'), ''), '/'))
);

-- 95% Wilson bounds for a rate (used so a flag means a real change, not noise)
CREATE OR REPLACE FUNCTION `commanding-air-450109-p0.bs_core.wilson_upper`(successes INT64, trials INT64)
RETURNS FLOAT64 AS (
  IF(trials = 0, NULL,
     (successes / trials + 1.9208 / trials
      + 1.96 * SQRT(successes / trials * (1 - successes / trials) / trials + 0.9604 / (trials * trials)))
     / (1 + 3.8416 / trials))
);
CREATE OR REPLACE FUNCTION `commanding-air-450109-p0.bs_core.wilson_lower`(successes INT64, trials INT64)
RETURNS FLOAT64 AS (
  IF(trials = 0, NULL,
     (successes / trials + 1.9208 / trials
      - 1.96 * SQRT(successes / trials * (1 - successes / trials) / trials + 0.9604 / (trials * trials)))
     / (1 + 3.8416 / trials))
);

-- Channel group: GA4's default group, with the three known Unassigned causes pulled out
CREATE OR REPLACE FUNCTION `commanding-air-450109-p0.bs_core.channel_group`(src STRING, med STRING, grp STRING)
RETURNS STRING AS (
  CASE
    WHEN REGEXP_CONTAINS(LOWER(IFNULL(src, '')), r'chatgpt|openai|perplexity|gemini|copilot|claude|anthropic') THEN 'AI assistants'
    WHEN REGEXP_CONTAINS(LOWER(IFNULL(src, '')), r'bonded') OR REGEXP_CONTAINS(LOWER(IFNULL(med, '')), r'^tv$|addressable') THEN 'TV (Bonded)'
    WHEN REGEXP_CONTAINS(LOWER(IFNULL(src, '')), r'linktr') THEN 'Linktree'
    ELSE COALESCE(grp, 'Unassigned')
  END
);

CREATE TABLE IF NOT EXISTS `commanding-air-450109-p0.bs_marts.trading_alerts` (
  rule_code STRING, entity_type STRING, entity_id STRING, entity_name STRING,
  metric_value FLOAT64, baseline_value FLOAT64, est_gbp_week FLOAT64, est_clicks_week FLOAT64,
  confidence STRING, owner_pillar STRING, priority STRING, recommended_action STRING, evidence STRING,
  first_seen DATE, last_seen DATE, run_count INT64
);

-- ---------- 1. product bridge ----------
BEGIN
  CREATE TABLE IF NOT EXISTS `commanding-air-450109-p0.bs_core.product_key_map` (
    source STRING NOT NULL, source_key STRING NOT NULL, product_group_id STRING NOT NULL
  );

  -- category = finest product_type level available (the peer group for benchmarks)
  CREATE OR REPLACE TABLE `commanding-air-450109-p0.bs_core.dim_product_group` AS
  SELECT
    `commanding-air-450109-p0.bs_core.model_key`(item_group_id) AS product_group_id,
    MAX(REPLACE(title, ' | Barker & Stonehouse', '')) AS product_name,
    CAST(NULL AS STRING) AS range_name,
    COALESCE(
      MAX(NULLIF(TRIM(SPLIT(product_type, '>')[SAFE_OFFSET(3)]), '')),
      MAX(NULLIF(TRIM(SPLIT(product_type, '>')[SAFE_OFFSET(2)]), '')),
      MAX(NULLIF(TRIM(SPLIT(product_type, '>')[SAFE_OFFSET(1)]), '')),
      MAX(NULLIF(TRIM(SPLIT(product_type, '>')[SAFE_OFFSET(0)]), '')),
      'Uncategorised') AS category,
    MAX(NULLIF(TRIM(SPLIT(product_type, '>')[SAFE_OFFSET(2)]), '')) AS broad_category,
    `commanding-air-450109-p0.bs_core.normalise_url`(MAX(IF(link != 'https://www.barkerandstonehouse.co.uk', link, NULL))) AS primary_url,
    TRUE AS is_live_online,
    SAFE_DIVIDE(COUNTIF(availability = 'in stock'), COUNT(*)) AS in_stock_share,
    CAST(NULL AS STRING) AS lead_time_band,
    FALSE AS is_store_exclusive
  FROM `commanding-air-450109-p0.google_ads_raw.product_feed`
  WHERE item_group_id IS NOT NULL
  GROUP BY product_group_id;

  CALL `commanding-air-450109-p0.bs_core.log_step`(run_ts, 'dim_product_group', 'ok', NULL);
EXCEPTION WHEN ERROR THEN
  CALL `commanding-air-450109-p0.bs_core.log_step`(run_ts, 'dim_product_group', 'error', @@error.message);
END;

-- ---------- 2. store gap (omni_product_gap) ----------
BEGIN
  DECLARE end_date   DATE DEFAULT (SELECT MAX(period_end) FROM `commanding-air-450109-p0.ometria.store_product_sales`);
  DECLARE start_date DATE DEFAULT (SELECT MIN(period_start) FROM `commanding-air-450109-p0.ometria.store_product_sales`
                                   WHERE period_end > DATE_SUB(end_date, INTERVAL 92 DAY));
  DECLARE ga4_capture FLOAT64 DEFAULT 1.0;  -- set from Data health: GA4 orders / Ometria online orders

  CREATE OR REPLACE TABLE `commanding-air-450109-p0.bs_marts.omni_product_gap` AS
  WITH store AS (
    SELECT
      COALESCE(o.product_group_id, `commanding-air-450109-p0.bs_core.model_key`(s.sku)) AS product_group_id,
      SUM(s.units_sold)     AS store_qty,
      SUM(IF(REGEXP_CONTAINS(UPPER(s.sku), r'(DISP|SAMP)$'), 0, s.units_sold)) AS store_qty_core,
      SUM(s.revenue_ex_vat) AS store_revenue
    FROM `commanding-air-450109-p0.ometria.store_product_sales` AS s
    LEFT JOIN `commanding-air-450109-p0.bs_core.product_key_map` AS o
      ON o.source = 'ometria' AND o.source_key = UPPER(TRIM(s.sku))
    WHERE s.period_end > DATE_SUB(end_date, INTERVAL 92 DAY)
    GROUP BY 1
  ),
  ga4 AS (
    SELECT
      COALESCE(o.product_group_id, `commanding-air-450109-p0.bs_core.model_key`(i.item_id)) AS product_group_id,
      e.event_name,
      i.quantity,
      CONCAT(e.user_pseudo_id, '.', CAST((SELECT value.int_value FROM UNNEST(e.event_params)
                                          WHERE key = 'ga_session_id') AS STRING)) AS session_key
    FROM `commanding-air-450109-p0.analytics_287404213.events_*` AS e
    CROSS JOIN UNNEST(e.items) AS i
    LEFT JOIN `commanding-air-450109-p0.bs_core.product_key_map` AS o
      ON o.source = 'ga4' AND o.source_key = UPPER(TRIM(i.item_id))
    WHERE _TABLE_SUFFIX BETWEEN FORMAT_DATE('%Y%m%d', start_date) AND FORMAT_DATE('%Y%m%d', end_date)
      AND e.event_name IN ('view_item', 'add_to_cart', 'purchase')
  ),
  web AS (
    SELECT
      product_group_id,
      COUNT(DISTINCT IF(event_name = 'view_item', session_key, NULL))   AS pdp_sessions,
      COUNT(DISTINCT IF(event_name = 'add_to_cart', session_key, NULL)) AS cart_sessions,
      SUM(IF(event_name = 'purchase', quantity, 0)) / ga4_capture       AS web_qty
    FROM ga4
    GROUP BY 1
  ),
  combined AS (
    SELECT
      s.product_group_id, s.store_qty, s.store_qty_core, s.store_revenue,
      d.product_name, d.category,
      COALESCE(d.lead_time_band, 'unknown')  AS lead_time_band,
      COALESCE(d.is_live_online, FALSE)      AS is_live_online,
      COALESCE(d.is_store_exclusive, FALSE)  AS is_store_exclusive,
      COALESCE(w.pdp_sessions, 0)            AS pdp_sessions,
      COALESCE(w.cart_sessions, 0)           AS cart_sessions,
      COALESCE(w.web_qty, 0)                 AS web_qty,
      SAFE_DIVIDE(COALESCE(w.web_qty, 0), COALESCE(w.web_qty, 0) + s.store_qty_core) AS web_share
    FROM store AS s
    LEFT JOIN web AS w USING (product_group_id)
    LEFT JOIN `commanding-air-450109-p0.bs_core.dim_product_group` AS d USING (product_group_id)
  ),
  norms AS (
    SELECT
      category, lead_time_band,
      SAFE_DIVIDE(SUM(web_qty), SUM(web_qty + store_qty_core))      AS peer_web_share,
      SAFE_DIVIDE(SUM(cart_sessions), SUM(pdp_sessions))            AS peer_cart_rate,
      SAFE_DIVIDE(SUM(pdp_sessions), SUM(store_qty_core + web_qty)) AS peer_views_per_unit
    FROM combined
    WHERE is_live_online
    GROUP BY category, lead_time_band
  ),
  site AS (
    SELECT SAFE_DIVIDE(SUM(web_qty), SUM(web_qty + store_qty_core)) AS site_web_share
    FROM combined
    WHERE is_live_online
  ),
  scored AS (
    SELECT
      c.*,
      COALESCE(n.peer_web_share, st.site_web_share) AS peer_web_share,
      n.peer_cart_rate, n.peer_views_per_unit
    FROM combined AS c
    LEFT JOIN norms AS n
      ON n.category IS NOT DISTINCT FROM c.category AND n.lead_time_band = c.lead_time_band
    CROSS JOIN site AS st
  )
  SELECT
    sc.*,
    ROUND(100 * SAFE_DIVIDE(sc.web_share, sc.peer_web_share)) AS web_share_index,
    CASE
      WHEN REGEXP_CONTAINS(sc.product_group_id, r'^[0-9]+$') THEN '0 Check mapping'
      WHEN sc.is_store_exclusive THEN 'Store exclusive'
      WHEN NOT sc.is_live_online THEN '1 Not listed online'
      WHEN SAFE_DIVIDE(sc.pdp_sessions, sc.store_qty_core + sc.web_qty) < 0.3 * sc.peer_views_per_unit THEN '2 Listed, undiscovered'
      WHEN SAFE_DIVIDE(sc.cart_sessions, sc.pdp_sessions) < 0.6 * sc.peer_cart_rate                     THEN '3 Viewed, not added'
      WHEN SAFE_DIVIDE(sc.web_share, sc.peer_web_share) < 0.5                                            THEN '4 Under-indexing online'
      ELSE 'OK'
    END AS gap_segment,
    ROUND(GREATEST(0, sc.store_qty_core * SAFE_DIVIDE(sc.peer_web_share, 1 - sc.peer_web_share) - sc.web_qty)
          * SAFE_DIVIDE(sc.store_revenue, sc.store_qty)) AS est_web_gap_ex_vat
  FROM scored AS sc
  WHERE sc.store_qty_core >= 5;

  CALL `commanding-air-450109-p0.bs_core.log_step`(run_ts, 'omni_product_gap', 'ok', NULL);
EXCEPTION WHEN ERROR THEN
  CALL `commanding-air-450109-p0.bs_core.log_step`(run_ts, 'omni_product_gap', 'error', @@error.message);
END;

-- ---------- 3. product pages (28 days) ----------
BEGIN
  CREATE OR REPLACE TABLE `commanding-air-450109-p0.bs_marts.pdp_scorecard` AS
  WITH ev AS (
    SELECT
      `commanding-air-450109-p0.bs_core.model_key`(i.item_id) AS product_group_id,
      e.event_name, i.quantity, i.item_revenue,
      CONCAT(e.user_pseudo_id, '.', CAST((SELECT value.int_value FROM UNNEST(e.event_params)
                                          WHERE key = 'ga_session_id') AS STRING)) AS session_key
    FROM `commanding-air-450109-p0.analytics_287404213.events_*` AS e
    CROSS JOIN UNNEST(e.items) AS i
    WHERE _TABLE_SUFFIX BETWEEN d28 AND yesterday
      AND e.event_name IN ('view_item', 'add_to_cart', 'purchase')
  ),
  m AS (
    SELECT
      product_group_id,
      COUNT(DISTINCT IF(event_name = 'view_item', session_key, NULL))   AS pdp_sessions,
      COUNT(DISTINCT IF(event_name = 'add_to_cart', session_key, NULL)) AS cart_sessions,
      COUNT(DISTINCT IF(event_name = 'purchase', session_key, NULL))    AS purchase_sessions,
      SUM(IF(event_name = 'purchase', quantity, 0))                     AS units,
      SUM(IF(event_name = 'purchase', item_revenue, 0))                 AS revenue
    FROM ev
    GROUP BY 1
  ),
  j AS (
    SELECT m.*, d.product_name, d.category, d.primary_url,
           SAFE_DIVIDE(m.cart_sessions, m.pdp_sessions) AS cart_rate
    FROM m
    JOIN `commanding-air-450109-p0.bs_core.dim_product_group` AS d USING (product_group_id)
    WHERE m.pdp_sessions >= 30
  ),
  peer AS (
    SELECT category,
           APPROX_QUANTILES(cart_rate, 100)[OFFSET(50)] AS peer_median_cart_rate,
           COUNT(*) AS peer_n
    FROM j
    WHERE pdp_sessions >= 100
    GROUP BY category
  ),
  site AS (
    SELECT SAFE_DIVIDE(SUM(purchase_sessions), SUM(cart_sessions)) AS site_order_rate,
           SAFE_DIVIDE(SUM(revenue), SUM(units)) AS site_avg_price
    FROM j
  ),
  scored AS (
    SELECT
      j.*, p.peer_median_cart_rate, p.peer_n, s.site_order_rate,
      COALESCE(SAFE_DIVIDE(j.revenue, j.units), s.site_avg_price) AS avg_price,
      PERCENT_RANK() OVER (PARTITION BY j.category ORDER BY j.pdp_sessions) AS sessions_pctile
    FROM j
    LEFT JOIN peer AS p USING (category)
    CROSS JOIN site AS s
  )
  SELECT
    scored.*,
    (peer_n >= 5 AND sessions_pctile >= 0.8
      AND cart_rate < 0.5 * peer_median_cart_rate
      AND `commanding-air-450109-p0.bs_core.wilson_upper`(cart_sessions, pdp_sessions) < peer_median_cart_rate) AS merch_review,
    ROUND(GREATEST(0, pdp_sessions * (peer_median_cart_rate - cart_rate)) * site_order_rate * avg_price / 4) AS est_gbp_week
  FROM scored;

  CALL `commanding-air-450109-p0.bs_core.log_step`(run_ts, 'pdp_scorecard', 'ok', NULL);
EXCEPTION WHEN ERROR THEN
  CALL `commanding-air-450109-p0.bs_core.log_step`(run_ts, 'pdp_scorecard', 'error', @@error.message);
END;

-- ---------- 4. landing pages and channel quality (28 days) ----------
BEGIN
  CREATE TEMP TABLE sess_28d AS
  WITH ev AS (
    SELECT
      user_pseudo_id, event_name, event_timestamp,
      (SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id') AS sid,
      (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'page_location') AS page_location,
      (SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'engagement_time_msec') AS eng_ms,
      session_traffic_source_last_click.cross_channel_campaign.default_channel_group AS grp,
      session_traffic_source_last_click.cross_channel_campaign.source AS src,
      session_traffic_source_last_click.cross_channel_campaign.medium AS med,
      ecommerce.purchase_revenue AS purchase_revenue,
      device.category AS device
    FROM `commanding-air-450109-p0.analytics_287404213.events_*`
    WHERE _TABLE_SUFFIX BETWEEN d28 AND yesterday
  )
  SELECT
    user_pseudo_id, sid,
    ARRAY_AGG(IF(event_name = 'page_view', page_location, NULL) IGNORE NULLS ORDER BY event_timestamp LIMIT 1)[SAFE_OFFSET(0)] AS landing,
    MAX(grp) AS grp, MAX(src) AS src, MAX(med) AS med, MAX(device) AS device,
    SUM(IFNULL(eng_ms, 0)) AS eng_ms,
    COUNTIF(event_name = 'page_view') AS pageviews,
    LOGICAL_OR(event_name = 'add_to_cart') AS cart,
    LOGICAL_OR(event_name = 'purchase') AS purchase,
    SUM(IF(event_name = 'purchase', purchase_revenue, 0)) AS revenue
  FROM ev
  WHERE sid IS NOT NULL
  GROUP BY user_pseudo_id, sid;

  CREATE OR REPLACE TABLE `commanding-air-450109-p0.bs_marts.channel_quality_28d` AS
  SELECT
    `commanding-air-450109-p0.bs_core.channel_group`(src, med, grp) AS channel_group,
    COALESCE(device, 'unknown') AS device,
    COUNT(*) AS sessions,
    COUNTIF(eng_ms >= 10000 OR pageviews >= 2 OR purchase) AS engaged_sessions,
    COUNTIF(cart) AS cart_sessions,
    COUNTIF(purchase) AS purchase_sessions,
    ROUND(SUM(revenue), 2) AS revenue
  FROM sess_28d
  GROUP BY channel_group, device;

  CREATE OR REPLACE TABLE `commanding-air-450109-p0.bs_marts.landing_pages_28d` AS
  WITH s AS (
    SELECT
      `commanding-air-450109-p0.bs_core.normalise_url`(landing) AS landing_path,
      `commanding-air-450109-p0.bs_core.channel_group`(src, med, grp) AS channel_group,
      (eng_ms >= 10000 OR pageviews >= 2 OR purchase) AS engaged,
      cart, purchase, revenue
    FROM sess_28d
    WHERE landing IS NOT NULL
  ),
  prod AS (
    SELECT DISTINCT primary_url FROM `commanding-air-450109-p0.bs_core.dim_product_group` WHERE primary_url IS NOT NULL
  )
  SELECT
    s.landing_path,
    CASE
      WHEN s.landing_path = '/' THEN 'Home'
      WHEN p.primary_url IS NOT NULL THEN 'Product page'
      WHEN REGEXP_CONTAINS(s.landing_path, r'^/(blog|inspiration|interior|news|guide|guides|customers|about)') THEN 'Content'
      ELSE 'Category and other'
    END AS page_type,
    s.channel_group,
    COUNT(*) AS sessions,
    COUNTIF(s.engaged) AS engaged_sessions,
    COUNTIF(s.cart) AS cart_sessions,
    COUNTIF(s.purchase) AS purchase_sessions,
    ROUND(SUM(s.revenue), 2) AS revenue
  FROM s
  LEFT JOIN prod AS p ON p.primary_url = s.landing_path
  GROUP BY s.landing_path, page_type, s.channel_group
  HAVING COUNT(*) >= 10;

  CALL `commanding-air-450109-p0.bs_core.log_step`(run_ts, 'landing_pages', 'ok', NULL);
EXCEPTION WHEN ERROR THEN
  CALL `commanding-air-450109-p0.bs_core.log_step`(run_ts, 'landing_pages', 'error', @@error.message);
END;

-- ---------- 5. on-site search (28 days) ----------
BEGIN
  CREATE OR REPLACE TABLE `commanding-air-450109-p0.bs_marts.search_terms_28d` AS
  WITH ev AS (
    SELECT
      event_name, event_timestamp,
      CONCAT(user_pseudo_id, '.', CAST((SELECT value.int_value FROM UNNEST(event_params)
                                        WHERE key = 'ga_session_id') AS STRING)) AS session_key,
      LOWER(TRIM((SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'search_term'))) AS term
    FROM `commanding-air-450109-p0.analytics_287404213.events_*`
    WHERE _TABLE_SUFFIX BETWEEN d28 AND yesterday
      AND event_name IN ('search', 'select_item', 'view_item')
  ),
  searches AS (
    SELECT term, session_key, event_timestamp AS ts FROM ev
    WHERE event_name = 'search' AND term IS NOT NULL AND term != ''
  ),
  last_click AS (
    SELECT session_key, MAX(event_timestamp) AS last_ts FROM ev
    WHERE event_name IN ('select_item', 'view_item')
    GROUP BY session_key
  ),
  by_term AS (
    SELECT s.term,
           COUNT(*) AS searches,
           COUNT(DISTINCT s.session_key) AS sessions,
           COUNT(DISTINCT IF(c.last_ts > s.ts, s.session_key, NULL)) AS sessions_with_click
    FROM searches AS s
    LEFT JOIN last_click AS c USING (session_key)
    GROUP BY s.term
    HAVING COUNT(*) >= 5
  ),
  store AS (
    SELECT m.mk, m.title, m.units, d.product_group_id IS NOT NULL AS listed
    FROM (
      SELECT `commanding-air-450109-p0.bs_core.model_key`(sku) AS mk, MAX(product_title) AS title, SUM(units_sold) AS units
      FROM `commanding-air-450109-p0.ometria.store_product_sales`
      GROUP BY mk
    ) AS m
    LEFT JOIN `commanding-air-450109-p0.bs_core.dim_product_group` AS d ON d.product_group_id = m.mk
  ),
  matched AS (
    SELECT t.term,
           SUM(s.units) AS store_units,
           ARRAY_AGG(s.title ORDER BY s.units DESC LIMIT 1)[OFFSET(0)] AS store_product,
           LOGICAL_OR(s.listed) AS listed_online
    FROM by_term AS t
    JOIN store AS s ON LENGTH(t.term) >= 4 AND STRPOS(LOWER(s.title), t.term) > 0
    GROUP BY t.term
  )
  SELECT t.term, t.searches, t.sessions, t.sessions_with_click,
         SAFE_DIVIDE(t.sessions_with_click, t.sessions) AS click_rate,
         m.store_units, m.store_product, m.listed_online
  FROM by_term AS t
  LEFT JOIN matched AS m USING (term);

  CALL `commanding-air-450109-p0.bs_core.log_step`(run_ts, 'search_terms', 'ok', NULL);
EXCEPTION WHEN ERROR THEN
  CALL `commanding-air-450109-p0.bs_core.log_step`(run_ts, 'search_terms', 'error', @@error.message);
END;

-- ---------- 6. product lists (28 days of select_item) ----------
BEGIN
  CREATE OR REPLACE TABLE `commanding-air-450109-p0.bs_marts.plp_clicks_28d` AS
  SELECT
    COALESCE(NULLIF(i.item_list_name, ''), '(not set)') AS list_name,
    COUNT(*) AS clicks,
    COUNTIF(SAFE_CAST(i.item_list_index AS INT64) IS NOT NULL) AS with_index,
    ROUND(AVG(SAFE_CAST(i.item_list_index AS INT64)), 1) AS avg_index,
    COUNTIF(SAFE_CAST(i.item_list_index AS INT64) <= 8) AS top8_clicks,
    COUNTIF(SAFE_CAST(i.item_list_index AS INT64) > 12) AS below12_clicks
  FROM `commanding-air-450109-p0.analytics_287404213.events_*` AS e
  CROSS JOIN UNNEST(e.items) AS i
  WHERE _TABLE_SUFFIX BETWEEN d28 AND yesterday
    AND e.event_name = 'select_item'
  GROUP BY list_name;

  CREATE OR REPLACE TABLE `commanding-air-450109-p0.bs_marts.plp_top_items_28d` AS
  SELECT list_name, product_group_id, ANY_VALUE(product_name) AS product_name, SUM(clicks) AS clicks
  FROM (
    SELECT
      COALESCE(NULLIF(i.item_list_name, ''), '(not set)') AS list_name,
      `commanding-air-450109-p0.bs_core.model_key`(i.item_id) AS product_group_id,
      COALESCE(d.product_name, i.item_name) AS product_name,
      1 AS clicks
    FROM `commanding-air-450109-p0.analytics_287404213.events_*` AS e
    CROSS JOIN UNNEST(e.items) AS i
    LEFT JOIN `commanding-air-450109-p0.bs_core.dim_product_group` AS d
      ON d.product_group_id = `commanding-air-450109-p0.bs_core.model_key`(i.item_id)
    WHERE _TABLE_SUFFIX BETWEEN d28 AND yesterday
      AND e.event_name = 'select_item'
  )
  GROUP BY list_name, product_group_id
  QUALIFY ROW_NUMBER() OVER (ORDER BY SUM(clicks) DESC) <= 300;

  CALL `commanding-air-450109-p0.bs_core.log_step`(run_ts, 'plp_clicks', 'ok', NULL);
EXCEPTION WHEN ERROR THEN
  CALL `commanding-air-450109-p0.bs_core.log_step`(run_ts, 'plp_clicks', 'error', @@error.message);
END;

-- ---------- 7. checkout funnel (60 days, by day and device) ----------
BEGIN
  CREATE OR REPLACE TABLE `commanding-air-450109-p0.bs_marts.checkout_funnel_daily`
  PARTITION BY event_date AS
  WITH ev AS (
    SELECT
      PARSE_DATE('%Y%m%d', event_date) AS event_date,
      device.category AS device,
      event_name,
      CONCAT(user_pseudo_id, '.', CAST((SELECT value.int_value FROM UNNEST(event_params)
                                        WHERE key = 'ga_session_id') AS STRING)) AS session_key,
      IF(event_name = 'purchase', ecommerce.purchase_revenue, 0) AS revenue
    FROM `commanding-air-450109-p0.analytics_287404213.events_*`
    WHERE _TABLE_SUFFIX BETWEEN d60 AND yesterday
      AND event_name IN ('session_start', 'page_view', 'view_item', 'add_to_cart', 'begin_checkout',
                         'add_shipping_info', 'add_payment_info', 'purchase')
  ),
  s AS (
    SELECT
      session_key,
      MIN(event_date)   AS event_date,
      ANY_VALUE(device) AS device,
      LOGICAL_OR(event_name = 'view_item')         AS pdp,
      LOGICAL_OR(event_name = 'add_to_cart')       AS cart,
      LOGICAL_OR(event_name = 'begin_checkout')    AS checkout,
      LOGICAL_OR(event_name = 'add_shipping_info') AS shipping,
      LOGICAL_OR(event_name = 'add_payment_info')  AS payment,
      LOGICAL_OR(event_name = 'purchase')          AS purchase,
      SUM(revenue) AS revenue
    FROM ev
    WHERE session_key IS NOT NULL
    GROUP BY session_key
  )
  SELECT
    event_date, COALESCE(device, 'unknown') AS device,
    COUNT(*)                          AS sessions,
    COUNTIF(pdp)                      AS pdp_sessions,
    COUNTIF(cart)                     AS cart_sessions,
    COUNTIF(checkout)                 AS checkout_sessions,
    COUNTIF(checkout AND shipping)    AS shipping_sessions,
    COUNTIF(checkout AND payment)     AS payment_sessions,
    COUNTIF(checkout AND purchase)    AS purchase_sessions,
    COUNTIF(purchase)                 AS purchase_all_sessions,
    ROUND(SUM(IF(checkout AND purchase, revenue, 0)), 2) AS revenue
  FROM s
  GROUP BY event_date, device;

  CALL `commanding-air-450109-p0.bs_core.log_step`(run_ts, 'checkout_funnel', 'ok', NULL);
EXCEPTION WHEN ERROR THEN
  CALL `commanding-air-450109-p0.bs_core.log_step`(run_ts, 'checkout_funnel', 'error', @@error.message);
END;

-- ---------- 8. time to purchase (90 days) ----------
-- Days between the browser's first visit and the order. It understates the true journey when
-- someone switches device or clears cookies.
BEGIN
  CREATE OR REPLACE TABLE `commanding-air-450109-p0.bs_marts.journey_days_90d` AS
  WITH p AS (
    SELECT
      ecommerce.transaction_id AS tid,
      MAX(DATE_DIFF(PARSE_DATE('%Y%m%d', event_date),
                    DATE(TIMESTAMP_MICROS(user_first_touch_timestamp), 'Europe/London'), DAY)) AS days,
      MAX(ecommerce.purchase_revenue) AS revenue
    FROM `commanding-air-450109-p0.analytics_287404213.events_*`
    WHERE _TABLE_SUFFIX BETWEEN d90 AND yesterday
      AND event_name = 'purchase' AND ecommerce.transaction_id IS NOT NULL
    GROUP BY tid
  ),
  b AS (
    SELECT
      CASE WHEN days <= 0 THEN 'Same day' WHEN days <= 7 THEN '1 to 7 days' WHEN days <= 30 THEN '8 to 30 days'
           WHEN days <= 90 THEN '31 to 90 days' ELSE 'Over 90 days' END AS bucket,
      CASE WHEN days <= 0 THEN 1 WHEN days <= 7 THEN 2 WHEN days <= 30 THEN 3 WHEN days <= 90 THEN 4 ELSE 5 END AS sort_order,
      revenue
    FROM p
  )
  SELECT bucket, sort_order, COUNT(*) AS purchases, ROUND(SUM(revenue)) AS revenue,
         (SELECT APPROX_QUANTILES(days, 2)[OFFSET(1)] FROM p) AS median_days
  FROM b
  GROUP BY bucket, sort_order;

  CALL `commanding-air-450109-p0.bs_core.log_step`(run_ts, 'journey_days', 'ok', NULL);
EXCEPTION WHEN ERROR THEN
  CALL `commanding-air-450109-p0.bs_core.log_step`(run_ts, 'journey_days', 'error', @@error.message);
END;

-- ---------- 9. alerts ----------
CREATE TEMP TABLE alerts_today (
  rule_code STRING, entity_type STRING, entity_id STRING, entity_name STRING,
  metric_value FLOAT64, baseline_value FLOAT64, est_gbp_week FLOAT64, est_clicks_week FLOAT64,
  confidence STRING, owner_pillar STRING, priority STRING, recommended_action STRING, evidence STRING
);

-- Alert: product page review (popular page, weak add-to-basket against similar products)
BEGIN
  INSERT INTO alerts_today
  SELECT 'PDP_MERCH_REVIEW', 'product', product_group_id, product_name, cart_rate, peer_median_cart_rate,
         est_gbp_week, NULL, IF(pdp_sessions >= 500, 'high', 'medium'), 'eCommerce', 'P2',
         'Review price against competitors, lead time shown, imagery and dimensions, fabric options and delivery information.',
         FORMAT('%d visits in 28 days; %.1f%% add to basket against a %.1f%% median for %s',
                pdp_sessions, 100 * cart_rate, 100 * peer_median_cart_rate, category)
  FROM `commanding-air-450109-p0.bs_marts.pdp_scorecard`
  WHERE merch_review AND est_gbp_week > 0;
  CALL `commanding-air-450109-p0.bs_core.log_step`(run_ts, 'alert_pdp', 'ok', NULL);
EXCEPTION WHEN ERROR THEN
  CALL `commanding-air-450109-p0.bs_core.log_step`(run_ts, 'alert_pdp', 'error', @@error.message);
END;

-- Alert: checkout step dropped against the same weekday over the previous four weeks
BEGIN
  INSERT INTO alerts_today
  WITH d AS (
    SELECT MAX(event_date) AS d0 FROM `commanding-air-450109-p0.bs_marts.checkout_funnel_daily` WHERE sessions > 0
  ),
  day AS (
    SELECT event_date, SUM(cart_sessions) AS cart, SUM(checkout_sessions) AS chk,
           SUM(purchase_sessions) AS pur, SUM(revenue) AS rev
    FROM `commanding-air-450109-p0.bs_marts.checkout_funnel_daily`
    GROUP BY event_date
  ),
  cur AS (SELECT day.* FROM day, d WHERE day.event_date = d.d0),
  base AS (
    SELECT SUM(cart) AS cart, SUM(chk) AS chk, SUM(pur) AS pur, SUM(rev) AS rev
    FROM day, d
    WHERE day.event_date IN (DATE_SUB(d.d0, INTERVAL 7 DAY), DATE_SUB(d.d0, INTERVAL 14 DAY),
                             DATE_SUB(d.d0, INTERVAL 21 DAY), DATE_SUB(d.d0, INTERVAL 28 DAY))
  ),
  steps AS (
    SELECT 'basket_to_checkout' AS id, 'Basket to checkout' AS nm, cur.chk AS succ, cur.cart AS n,
           SAFE_DIVIDE(cur.chk, cur.cart) AS rate, SAFE_DIVIDE(base.chk, base.cart) AS base_rate,
           SAFE_DIVIDE(base.rev, base.chk) AS value_per_success
    FROM cur, base
    UNION ALL
    SELECT 'checkout_to_purchase', 'Checkout to purchase', cur.pur, cur.chk,
           SAFE_DIVIDE(cur.pur, cur.chk), SAFE_DIVIDE(base.pur, base.chk),
           SAFE_DIVIDE(base.rev, base.pur)
    FROM cur, base
  )
  SELECT 'CHECKOUT_STEP_BREAK', 'step', id, nm, rate, base_rate,
         7 * (base_rate - rate) * n * value_per_success, NULL, IF(n >= 300, 'high', 'medium'), 'eCommerce',
         IF(id = 'checkout_to_purchase' AND rate < 0.8 * base_rate, 'P1', 'P2'),
         'Check payment providers, recent releases, delivery messaging and postcode rules; split by device and browser.',
         FORMAT('%.1f%% against %.1f%% on the same weekday over the last four weeks (%d entrants)', 100 * rate, 100 * base_rate, n)
  FROM steps
  WHERE n >= 100 AND base_rate IS NOT NULL
    AND `commanding-air-450109-p0.bs_core.wilson_upper`(succ, n) < base_rate;
  CALL `commanding-air-450109-p0.bs_core.log_step`(run_ts, 'alert_checkout', 'ok', NULL);
EXCEPTION WHEN ERROR THEN
  CALL `commanding-air-450109-p0.bs_core.log_step`(run_ts, 'alert_checkout', 'error', @@error.message);
END;

-- Alert: hidden gem (pages that earn well per visit but get little traffic)
BEGIN
  INSERT INTO alerts_today
  WITH pg AS (
    SELECT landing_path, ANY_VALUE(page_type) AS page_type, SUM(sessions) AS sessions,
           SUM(revenue) AS revenue, SAFE_DIVIDE(SUM(revenue), SUM(sessions)) AS rps
    FROM `commanding-air-450109-p0.bs_marts.landing_pages_28d`
    GROUP BY landing_path
  ),
  med AS (
    SELECT page_type,
           APPROX_QUANTILES(rps, 100)[OFFSET(50)] AS med_rps,
           APPROX_QUANTILES(sessions, 100)[OFFSET(50)] AS med_sessions
    FROM pg WHERE sessions >= 100
    GROUP BY page_type
  )
  SELECT 'HIDDEN_GEM', 'page', pg.landing_path, pg.landing_path, pg.rps, med.med_rps,
         LEAST(pg.sessions, GREATEST(0, med.med_sessions - pg.sessions)) * pg.rps / 4, NULL, 'medium', 'Paid Media', 'P2',
         'Give it more traffic: Shopping custom label, email and social features, top category slots and internal links.',
         FORMAT('%d sessions in 28 days at £%.2f a session, against £%.2f for the typical %s', pg.sessions, pg.rps, med.med_rps, LOWER(pg.page_type))
  FROM pg
  JOIN med USING (page_type)
  WHERE pg.sessions >= 300 AND pg.sessions < med.med_sessions AND med.med_rps > 0 AND pg.rps >= 1.5 * med.med_rps;
  CALL `commanding-air-450109-p0.bs_core.log_step`(run_ts, 'alert_hidden_gem', 'ok', NULL);
EXCEPTION WHEN ERROR THEN
  CALL `commanding-air-450109-p0.bs_core.log_step`(run_ts, 'alert_hidden_gem', 'error', @@error.message);
END;

-- Alert: store bestseller under-indexing online (top 100 by store sales, biggest 25 gaps)
BEGIN
  INSERT INTO alerts_today
  WITH t AS (
    SELECT `commanding-air-450109-p0.bs_core.model_key`(sku) AS mk, MAX(product_title) AS title
    FROM `commanding-air-450109-p0.ometria.store_product_sales`
    GROUP BY mk
  ),
  r AS (
    SELECT g.*, t.title, RANK() OVER (ORDER BY g.store_revenue DESC) AS rev_rank
    FROM `commanding-air-450109-p0.bs_marts.omni_product_gap` AS g
    LEFT JOIN t ON t.mk = g.product_group_id
  ),
  w AS (
    SELECT GREATEST(1, DATE_DIFF(MAX(period_end), MIN(period_start), DAY) / 7) AS weeks
    FROM `commanding-air-450109-p0.ometria.store_product_sales`
  )
  SELECT 'STORE_BESTSELLER_GAP', 'product', r.product_group_id, COALESCE(r.product_name, r.title),
         r.web_share, r.peer_web_share, r.est_web_gap_ex_vat / w.weeks, NULL,
         IF(r.gap_segment LIKE '1%', 'high', 'medium'), 'eCommerce', 'P2',
         CASE
           WHEN r.gap_segment LIKE '1%' THEN 'Add it to the website.'
           WHEN r.gap_segment LIKE '2%' THEN 'Make it findable: navigation, on-site search, internal links and category position.'
           WHEN r.gap_segment LIKE '3%' THEN 'Fix the page: price, delivery, images and fabric options. Check whether customers prefer to try it in store first.'
           ELSE 'Push traffic: Shopping, email and social, and add find-in-store prompts.'
         END,
         FORMAT('%d sold in store, %d online (%s)', CAST(r.store_qty_core AS INT64), CAST(ROUND(r.web_qty) AS INT64), r.gap_segment)
  FROM r, w
  WHERE r.rev_rank <= 100 AND r.gap_segment IN ('1 Not listed online', '2 Listed, undiscovered', '3 Viewed, not added', '4 Under-indexing online')
  QUALIFY ROW_NUMBER() OVER (ORDER BY r.est_web_gap_ex_vat DESC) <= 25;
  CALL `commanding-air-450109-p0.bs_core.log_step`(run_ts, 'alert_store_gap', 'ok', NULL);
EXCEPTION WHEN ERROR THEN
  CALL `commanding-air-450109-p0.bs_core.log_step`(run_ts, 'alert_store_gap', 'error', @@error.message);
END;

-- Merge today's alerts. run_count counts the days an alert has been seen; a gap of over a week starts it again.
BEGIN
  MERGE `commanding-air-450109-p0.bs_marts.trading_alerts` AS t
  USING (
    SELECT * FROM alerts_today
    QUALIFY ROW_NUMBER() OVER (PARTITION BY rule_code, entity_id ORDER BY est_gbp_week DESC) = 1
  ) AS s
  ON t.rule_code = s.rule_code AND t.entity_id = s.entity_id
  WHEN MATCHED THEN UPDATE SET
    entity_name = s.entity_name, metric_value = s.metric_value, baseline_value = s.baseline_value,
    est_gbp_week = s.est_gbp_week, est_clicks_week = s.est_clicks_week, confidence = s.confidence,
    owner_pillar = s.owner_pillar, priority = s.priority, recommended_action = s.recommended_action,
    evidence = s.evidence,
    first_seen = IF(t.last_seen >= DATE_SUB(today, INTERVAL 7 DAY), t.first_seen, today),
    run_count  = IF(t.last_seen = today, t.run_count, IF(t.last_seen >= DATE_SUB(today, INTERVAL 7 DAY), t.run_count + 1, 1)),
    last_seen  = today
  WHEN NOT MATCHED THEN INSERT
    (rule_code, entity_type, entity_id, entity_name, metric_value, baseline_value, est_gbp_week, est_clicks_week,
     confidence, owner_pillar, priority, recommended_action, evidence, first_seen, last_seen, run_count)
  VALUES
    (s.rule_code, s.entity_type, s.entity_id, s.entity_name, s.metric_value, s.baseline_value, s.est_gbp_week, s.est_clicks_week,
     s.confidence, s.owner_pillar, s.priority, s.recommended_action, s.evidence, today, today, 1);
  CALL `commanding-air-450109-p0.bs_core.log_step`(run_ts, 'alerts_merge', 'ok', NULL);
EXCEPTION WHEN ERROR THEN
  CALL `commanding-air-450109-p0.bs_core.log_step`(run_ts, 'alerts_merge', 'error', @@error.message);
END;

# Opportunities and Optimisations Dashboard

Barker and Stonehouse trading dashboard. It blends GA4, Ometria and Search Console in BigQuery and shows what to fix, what to scale and which store bestsellers are missing online.

## Set up (once)

1. **Main build.** In the BigQuery console open a new query, choose **More > Query settings > Data location > europe-west2**, paste `sql/01_build_europe-west2.sql` and run it. It takes a few minutes.
2. **Search Console build.** New query, location **EU**, paste `sql/02_build_eu_search-console.sql` and run it.
3. **Check it.** Open the dashboard, then **Data health**. The first table lists every build step with a green tick or a red cross and the error text. Paste any error text back and it is a quick fix.
4. **Schedule both.** In each query choose **Schedule > Create new scheduled query**: script 01 daily at about 07:00, script 02 daily at about 07:30, each in its own location.
5. **Publish.** Copy the `bs-opportunities` folder into your GitHub Pages repository and push it with GitHub Desktop. The OAuth client ID is already set to the one your other dashboards use.

Anyone who opens the dashboard needs BigQuery Job User on the project and Data Viewer on `bs_marts`, `bs_core`, `ometria`, `google_ads_raw`, the GA4 dataset and `gsc_marts`.

## Every week

1. Reload `ometria.orders_full` as you do now.
2. Export the Ometria products list for the last complete Monday to Sunday week, with web orders filtered out.
3. Run `py tools\clean_store_export.py "export.csv" --start 2026-10-05 --end 2026-10-11` (use that week's dates).
4. Upload the `_clean.csv` to `ometria.store_product_sales` in BigQuery with **Append to table**. Never load overlapping periods, or units are counted twice.

The opportunity list uses the latest 13 weeks of store sales, so it keeps itself current as weeks are appended.

## What each tab does

| Tab | What it tells the team |
| --- | --- |
| Overview | The headline: products that sell in store and are not on the website, plus where the rest of the opportunity sits. |
| Actions | Every alert in one list with the evidence, who owns it and what it is worth. Confirmed once seen on two days. |
| Store gap | The full product list by opportunity type, with filters and a CSV download. |
| Organic search | Title and description rewrites, pages close to page one, pages losing clicks, brand against non-brand. |
| Landing pages | Traffic quality by channel, hidden gems and leaky buckets. Unassigned split into TV, Linktree and AI. |
| Site search | Searches for products sold in store but not online, and searches that lead nowhere. |
| Product lists | Clicks by list. Positions appear once the site sends them. |
| Product pages | Popular pages that add to basket far below similar products. |
| Checkout | The funnel by device, rolling completion rates and the last 14 days. |
| Journeys | Days from first visit to order. |
| Data health | Build results, freshness, store-to-feed matching, feed quality and tracking gaps. |

## Known limits

- `ga4_capture` in script 01 defaults to 1.0. If GA4 records fewer orders than Ometria online orders, set it to that ratio so online units are not understated.
- The feed has no lead time, so products are compared within category only. A lead-time source (for example the Quick Delivery badge) would sharpen this.
- Product lists cannot show underperforming positions until the site sends `view_item_list` and `item_list_index`.
- Search cannot show zero-result searches until `search_results_count` is sent.
- `sample_order` and `see_in_store` carry no product, so swatch and showroom effects are not measured yet.
- Opportunity figures rank products. They are not forecasts.

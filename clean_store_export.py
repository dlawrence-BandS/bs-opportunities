"""Prepare an Ometria products-list export (web orders filtered out) for BigQuery.

Usage (Windows):
    py clean_store_export.py "products_list_report.csv" --start 2026-10-05 --end 2026-10-11

Writes <input>_clean.csv with numeric columns and period_start / period_end added.
Upload it in the BigQuery console to ometria.store_product_sales with "Append to table".
Use complete weeks (Monday to Sunday) and never overlap periods, or units are counted twice.
"""
import argparse
import csv
import re
import sys
from pathlib import Path

COLUMNS = ["sku", "product_id", "product_title", "units_sold", "unique_orders", "unique_customers",
           "revenue_ex_vat", "revenue_inc_vat", "discount", "first_time_orders", "list_price",
           "period_start", "period_end"]

def num(v):
    v = re.sub(r"[£,]", "", str(v or "")).strip()
    return v if re.fullmatch(r"-?\d+(\.\d+)?", v) else ""

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("export")
    ap.add_argument("--start", required=True, help="first day of the period, YYYY-MM-DD")
    ap.add_argument("--end", required=True, help="last day of the period, YYYY-MM-DD")
    a = ap.parse_args()
    for d in (a.start, a.end):
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", d):
            sys.exit("Dates must look like 2026-10-05")
    src = Path(a.export)
    out = src.with_name(src.stem + "_clean.csv")
    n = 0
    with open(src, newline="", encoding="utf-8-sig") as f, open(out, "w", newline="", encoding="utf-8") as g:
        r = csv.DictReader(f)
        need = ["Product ID", "Product SKU", "Product title", "Units sold", "Product revenue"]
        missing = [c for c in need if c not in (r.fieldnames or [])]
        if missing:
            sys.exit("This does not look like the Ometria products export. Missing columns: " + ", ".join(missing))
        w = csv.writer(g)
        w.writerow(COLUMNS)
        for row in r:
            sku = (row.get("Product SKU") or "").strip()
            if not sku:
                continue
            w.writerow([sku, (row.get("Product ID") or "").strip(), row.get("Product title", ""),
                        num(row.get("Units sold")), num(row.get("Unique orders")), num(row.get("Unique customers")),
                        num(row.get("Product revenue")), num(row.get("Product revenue with tax")),
                        num(row.get("Product discount")), num(row.get("First time orders")), num(row.get("Price")),
                        a.start, a.end])
            n += 1
    print(f"Wrote {n} rows to {out}")

if __name__ == "__main__":
    main()

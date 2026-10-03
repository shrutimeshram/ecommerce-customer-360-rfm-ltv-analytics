# E-Commerce Customer 360, RFM & LTV Analytics

End-to-end customer analytics project built with **Google BigQuery, SQL, Python and Power BI**. It turns raw Google Analytics 4 e-commerce events into a Customer 360 view, segments customers with RFM, analyzes the purchase funnel and cohort retention, estimates revenue at risk, and applies machine learning for churn, future revenue (LTV) and customer clustering.

**Tools:** BigQuery SQL · Python (Pandas, Scikit-learn, XGBoost) · Power BI (DAX)

## Dataset

Google Analytics 4 public sample e-commerce dataset in BigQuery: `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*` (about 92 days, Nov 2020 – Jan 2021).

| Metric | Value |
|---|---|
| Raw events | 4,295,584 |
| Unique anonymous users | 270,154 |
| Valid cleaned transactions | 4,466 |
| Customers with valid transactions | 3,713 |
| Clean transaction revenue | $330,348 |

## Workflow

1. **Data cleaning (BigQuery):** removed missing and `(not set)` transaction IDs and built a clean transaction table.
2. **Customer 360:** combined purchase metrics with engagement (product views, add-to-cart, checkout, page views).
3. **RFM segmentation:** NTILE-based Recency, Frequency and Monetary scores mapped to segments such as Champions, Loyal Customers and High Value At Risk.
4. **Funnel and cohort analysis:** view → cart → checkout → purchase conversion and monthly cohort retention.
5. **Revenue at risk:** scenario-based risk factors applied per segment.
6. **Machine learning (Python):**
   - Churn classification (Logistic Regression, Random Forest, XGBoost).
   - Two-stage future revenue (LTV) model on rolling snapshots: purchase-probability classifier plus revenue regressor.
   - K-Means customer clustering on 9 standardized behavioral features.
7. **Power BI dashboard:** 4 pages covering Customer 360 and revenue risk, cohort retention, customer risk, and ML insights.

## Key Results

- **Funnel:** View-to-Cart 18.14%, Cart-to-Checkout 37.49%, Checkout-to-Purchase 51.19%.
- **Revenue at risk:** $101,166 estimated under the scenario assumptions; 600 customers classified as High Value At Risk.
- **Churn model:** Random Forest reached F1 0.888 (accuracy 0.804).
- **Two-stage LTV model:** Stage 1 classifier ROC-AUC 0.955. Predicted $12,451 against $11,609 actual future revenue (ratio 1.07).
- **Clustering:** K = 2 (silhouette 0.4455). The high-value / highly engaged cluster has 608 customers with an average revenue of $190 against $67 for the rest.

## Repository Structure

```
notebooks/   Python analysis and ML notebook (Kaggle)
sql/         BigQuery SQL: cleaning, Customer 360, RFM, funnel, cohort, risk
powerbi/     Power BI report (.pbix) and DAX measures
data/        BigQuery exports and ML output tables
docs/        Full project documentation
```

## Limitations

- The GA4 sample is obfuscated and uses an anonymous `user_pseudo_id`.
- The 92-day window limits long-term retention and true lifetime-value measurement.
- Revenue at risk is a scenario estimate based on defined risk factors, not observed loss.

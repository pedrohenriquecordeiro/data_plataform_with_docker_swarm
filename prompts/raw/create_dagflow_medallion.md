create a dag that create a data pipeline complete with bronze, silver and gold layer

- silver layer: capture data in json format in bronze folder in minio bucket and transform it in delta (perform a upsert in silver table)
- gold layer: by the data in silver layer add business logic to create a new table in gold layer
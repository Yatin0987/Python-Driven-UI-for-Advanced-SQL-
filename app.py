import streamlit as st
import pandas as pd
from psycopg2.extras import RealDictCursor

# Removed 'tornado' as it is generally not required for standard Streamlit apps
# unless you have a very specific server configuration.

# Ensure the function names in your db_functions.py match these imports
from db_functions import (
    connect_to_db,
    get_basic_info,
    get_additonal_tables,  # Fixed typo: additonal -> additional
    get_categories,
    get_suppliers,
    add_new_manual_id,
    get_all_products,
    get_product_history,
    place_reorder,
    get_pending_reorders,
    mark_reorder_as_received
)

# ---------------- CONFIG & SIDEBAR ----------------
st.set_page_config(page_title="Inventory Dashboard", layout="wide")

st.sidebar.title("Inventory Management")
menu = st.sidebar.radio(
    "Select Option:",
    ["Basic Information", "Operational Tasks"]
)

# Main Title
st.title("Inventory and Supply Chain Dashboard")

# DB Connection
# Note: In a production app, consider using st.cache_resource for the connection
db = connect_to_db()
cursor = db.cursor(cursor_factory=RealDictCursor)

# ---------------- BASIC INFORMATION PAGE ----------------
if menu == "Basic Information":
    st.header("Basic Metrics")

    try:
        # Get data from DB
        basic_info = get_basic_info(cursor)

        if basic_info:
            keys = list(basic_info.keys())

            # Row 1 Metrics
            cols1 = st.columns(3)
            for i in range(min(3, len(keys))):
                cols1[i].metric(label=keys[i], value=basic_info[keys[i]])

            # Row 2 Metrics (Safety check for index existence)
            if len(keys) > 3:
                cols2 = st.columns(3)
                for i in range(3, min(6, len(keys))):
                    cols2[i - 3].metric(label=keys[i], value=basic_info[keys[i]])
        else:
            st.warning("No basic metrics found.")

        st.divider()

        # Fetch and display detailed tables
        tables = get_additonal_tables(cursor)

        if tables:
            for label, data in tables.items():
                st.subheader(label)
                df = pd.DataFrame(data)
                st.dataframe(df, use_container_width=True)
                st.divider()

    except Exception as e:
        st.error(f"Error loading Basic Information: {e}")

# ---------------- OPERATIONAL TASKS PAGE ----------------
elif menu == "Operational Tasks":
    st.header("Operational Tasks")

    selected_task = st.selectbox(
        "Select Action:",
        ["Add New Product", "Product History", "Place Reorder", "Receive Reorder"]
    )

    # --- TASK 1: ADD NEW PRODUCT ---
    if selected_task == "Add New Product":
        st.subheader("Add New Product")

        try:
            categories = get_categories(cursor)
            suppliers = get_suppliers(cursor)

            # Extract lists for the selectbox
            supplier_ids = [s["supplier_id"] for s in suppliers]
            supplier_names = [s["supplier_name"] for s in suppliers]

            with st.form("Add_Product_Form"):
                col1, col2 = st.columns(2)
                with col1:
                    product_name = st.text_input("Product Name")
                    product_categories = st.selectbox("Category", categories)
                    product_price = st.number_input("Price", min_value=0.0, format="%.2f")

                with col2:
                    product_stock = st.number_input("Stock Quantity", min_value=0, step=1)
                    product_level = st.number_input("Reorder Level", min_value=0, step=1)
                    supplier_id = st.selectbox(
                        "Supplier",
                        options=supplier_ids,
                        format_func=lambda x: supplier_names[supplier_ids.index(x)] if x in supplier_ids else x
                    )

                submitted = st.form_submit_button("Add Product")

                if submitted:
                    if not product_name:
                        st.error("Please enter the Product Name.")
                    else:
                        try:
                            add_new_manual_id(
                                cursor, db, product_name, product_categories,
                                product_price, product_stock, product_level, supplier_id
                            )
                            st.success(f"Product '{product_name}' added successfully.")
                        except Exception as e:
                            st.error(f"Error adding product: {e}")
        except Exception as e:
            st.error(f"Error loading form data: {e}")

    # --- TASK 2: PRODUCT HISTORY ---
    elif selected_task == "Product History":
        st.subheader("Product Inventory History")

        try:
            products = get_all_products(cursor)
            if products:
                product_names = [p['product_name'] for p in products]
                product_ids = [p['product_id'] for p in products]

                selected_product_name = st.selectbox("Select a Product", options=product_names)

                if selected_product_name:
                    selected_product_id = product_ids[product_names.index(selected_product_name)]
                    history_data = get_product_history(cursor, selected_product_id)

                    if history_data:
                        df = pd.DataFrame(history_data)
                        st.dataframe(df, use_container_width=True)
                    else:
                        st.info("No history found for the selected product.")
            else:
                st.warning("No products found in database.")
        except Exception as e:
            st.error(f"Error fetching history: {e}")

    # --- TASK 3: PLACE REORDER ---
    elif selected_task == "Place Reorder":
        st.subheader("Place a Reorder")

        try:
            products = get_all_products(cursor)
            if products:
                product_names = [p['product_name'] for p in products]
                product_ids = [p['product_id'] for p in products]

                col1, col2 = st.columns(2)
                with col1:
                    selected_product_name = st.selectbox("Select a Product", options=product_names)
                with col2:
                    reorder_qty = st.number_input("Reorder Quantity", min_value=1, step=1)

                if st.button("Place Reorder", type="primary"):
                    if not selected_product_name:
                        st.error("Please select a product.")
                    else:
                        selected_product_id = product_ids[product_names.index(selected_product_name)]
                        try:
                            place_reorder(cursor, db, selected_product_id, reorder_qty)
                            st.success(f"Order placed for {selected_product_name} (Qty: {reorder_qty})")
                        except Exception as e:
                            st.error(f"Error placing reorder: {e}")
            else:
                st.warning("No products available to reorder.")
        except Exception as e:
            st.error(f"Error loading products: {e}")

    # --- TASK 4: RECEIVE REORDER ---
    elif selected_task == "Receive Reorder":
        st.subheader("Mark Reorder as Received")

        try:
            pending_reorders = get_pending_reorders(cursor)

            if not pending_reorders:
                st.info("No pending orders to receive.")
            else:
                # Create a readable label for the dropdown
                reorder_ids = [r['reorder_id'] for r in pending_reorders]
                reorder_labels = [f"ID {r['reorder_id']} - {r['product_name']} (Qty: {r.get('quantity', 'N/A')})" for r
                                  in pending_reorders]

                selected_label = st.selectbox("Select Reorder to Mark as Received", options=reorder_labels)

                if st.button("Mark as Received", type="primary"):
                    if selected_label:
                        # Find the ID corresponding to the label
                        selected_reorder_id = reorder_ids[reorder_labels.index(selected_label)]
                        try:
                            mark_reorder_as_received(cursor, db, selected_reorder_id)
                            st.success(f"Reorder ID {selected_reorder_id} marked as received.")
                            st.rerun()  # Refresh page to remove the item from the list
                        except Exception as e:
                            st.error(f"Error updating status: {e}")
        except Exception as e:
            st.error(f"Error fetching pending reorders: {e}")

# Close DB connection at the end of the script run (optional, depending on how db_functions handles it)
# db.close()
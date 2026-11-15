// =====================================================================
// Portfolio 4 - 02_queries.js   (run: mongosh --quiet ojahub 02_queries.js)
// The same OjaHub workloads as Portfolio 2, re-expressed for the
// document model, with explain() evidence and a cross-check against SQL.
// =====================================================================
db = db.getSiblingDB("ojahub");
const hr = t => print("\n######## " + t + " ########");
const brief = e => {               // compact executionStats summary
  const s = e.executionStats;
  let st = e.queryPlanner.winningPlan, stages = [];
  while (st) { stages.push(st.stage + (st.indexName ? "(" + st.indexName + ")" : "")); st = st.inputStage || (st.inputStages || [])[0]; }
  return `plan=${stages.join(" <- ")} | keysExamined=${s.totalKeysExamined} docsExamined=${s.totalDocsExamined} returned=${s.nReturned} time=${s.executionTimeMillis}ms`;
};

hr("M1  Customer order history: one collection, no join (SQL Q1 needed customer JOIN customer_order)");
const cid = db.customers.findOne({ email: "chinedu.ibrahim1207@outlook.com" })._id;
db.orders.find({ "customer.customer_id": cid }, { order_date: 1, status: 1, "totals.total": 1 })
  .sort({ order_date: -1 }).limit(3).forEach(d => printjson(d));
print("with index   : " + brief(db.orders.find({ "customer.customer_id": cid }).sort({ order_date: -1 }).limit(10).explain("executionStats")));
print("forced scan  : " + brief(db.orders.find({ "customer.customer_id": cid }).sort({ order_date: -1 }).limit(10).hint({ $natural: 1 }).explain("executionStats")));

hr("M2  Tracking page: shipment + all events come back in ONE document read");
const any = db.orders.findOne({ "shipment.status": "DELIVERED" }, { "shipment.tracking_number": 1 });
printjson(db.orders.findOne({ "shipment.tracking_number": any.shipment.tracking_number },
  { _id: 1, status: 1, "shipment.courier": 1, "shipment.tracking_number": 1, "shipment.events": 1 }));
print(brief(db.orders.find({ "shipment.tracking_number": any.shipment.tracking_number }).explain("executionStats")));

hr("M3  Flexible attributes: 5G smartphones, >= 8 GB RAM, >= 256 GB storage, under NGN 400,000");
const q3 = { "category.leaf": "Smartphones", "attributes.ram_gb": { $gte: 8 }, "attributes.storage_gb": { $gte: 256 },
             "attributes.network": "5G", price: { $lte: NumberDecimal("400000") } };
db.products.find(q3, { _id: 0, name: 1, price: 1, "attributes.ram_gb": 1, "attributes.storage_gb": 1, "rating.avg": 1 })
  .sort({ price: 1 }).limit(5).forEach(d => printjson(d));
print("matching products: " + db.products.countDocuments(q3));
print(brief(db.products.find(q3).sort({ price: 1 }).explain("executionStats")));
print("Same product collection also holds shoes with sizes_eu and rice with nafdac_no, e.g.:");
printjson(db.products.findOne({ "category.leaf": "Footwear" }, { _id: 0, name: 1, attributes: 1 }));
printjson(db.products.findOne({ "category.leaf": "Food Cupboard" }, { _id: 0, name: 1, attributes: 1 }));
print("Wildcard index query on any attribute (halal groceries): " +
  brief(db.products.find({ "attributes.halal": true, "attributes.net_weight_kg": { $gte: 10 } }).explain("executionStats")));

hr("M4  Aggregation pipeline: 2026 revenue per geo-zone for Sep-Oct (cross-check with SQL Q3)");
db.orders.aggregate([
  { $match: { order_date: { $gte: ISODate("2026-08-31T23:00:00Z"), $lt: ISODate("2026-10-31T23:00:00Z") },
              status: { $in: ["PAID", "SHIPPED", "DELIVERED"] } } },
  { $group: { _id: { zone: "$ship_to.geo_zone",
                     month: { $dateToString: { format: "%Y-%m", date: "$order_date", timezone: "Africa/Lagos" } } },
              orders: { $sum: 1 }, revenue: { $sum: "$totals.total" } } },
  { $sort: { "_id.zone": 1, "_id.month": 1 } }
]).forEach(r => print(`${r._id.zone.padEnd(14)} ${r._id.month}  orders=${String(r.orders).padStart(5)}  revenue=${r.revenue}`));

hr("M5  Top 3 products per top-level category, last 90 days ($unwind + $group + $setWindowFields)");
db.orders.aggregate([
  { $match: { order_date: { $gte: ISODate("2026-08-01T23:00:00Z") }, status: { $ne: "CANCELLED" } } },
  { $unwind: "$items" },
  { $group: { _id: "$items.product_id", name: { $first: "$items.name" },
              units: { $sum: "$items.qty" }, revenue: { $sum: { $multiply: ["$items.qty", "$items.unit_price"] } } } },
  { $lookup: { from: "products", localField: "_id", foreignField: "_id", as: "p", pipeline: [{ $project: { "category.top": 1 } }] } },
  { $set: { top: { $first: "$p.category.top" } } },
  { $setWindowFields: { partitionBy: "$top", sortBy: { revenue: -1 }, output: { rnk: { $denseRank: {} } } } },
  { $match: { rnk: { $lte: 3 } } },
  { $sort: { top: 1, rnk: 1 } }, { $limit: 9 }
]).forEach(r => print(`${r.top.padEnd(17)} #${r.rnk} ${r.name.padEnd(36)} units=${r.units} revenue=${r.revenue}`));

hr("M6  Full-text search 'air fryer' (text index, relevance score)");
db.products.find({ $text: { $search: "\"air fryer\"" } }, { score: { $meta: "textScore" }, name: 1, price: 1, _id: 0 })
  .sort({ score: { $meta: "textScore" } }).limit(3).forEach(d => printjson(d));

hr("M7  Atomic single-document update: courier scan appends an event and changes status");
const target = db.orders.findOne({ status: "SHIPPED" }, { _id: 1 });
const res = db.orders.updateOne({ _id: target._id, status: "SHIPPED" },
  { $push: { "shipment.events": { status: "OUT_FOR_DELIVERY", location: "Lekki", at: new Date() } },
    $set: { "shipment.status": "OUT_FOR_DELIVERY" } });
printjson({ order: target._id, matched: res.matchedCount, modified: res.modifiedCount,
            events_now: db.orders.findOne({ _id: target._id }).shipment.events.length });

hr("M8  Schema validation rejects a malformed order");
try {
  db.orders.insertOne({ _id: 999999999, customer: { customer_id: 1 }, status: "SHIPPED_TO_MARS",
                        order_date: new Date(), items: [], totals: { total: 100 } });
} catch (e) { print("REJECTED: " + e.errmsg + "  ->  " + JSON.stringify(e.errInfo.details.schemaRulesNotSatisfied.map(r => r.propertiesNotSatisfied ? r.propertiesNotSatisfied.map(p => p.propertyName) : r.operatorName))); }

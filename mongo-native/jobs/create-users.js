//
// MongoDB User Bootstrap
// Idempotent
//

try {

db = db.getSiblingDB("admin");

db.createUser({
    user: _getEnv("MONGO_ADMIN_USER"),
    pwd: _getEnv("MONGO_ADMIN_PASSWORD"),
    roles: [
        {
            role: "root",
            db: "admin"
        }
    ]
});

print("Admin user created");

} catch (e) {

print("Admin user already exists");

}

try {

db = db.getSiblingDB(_getEnv("SHOPIXY_DB"));

db.createUser({
    user: _getEnv("SHOPIXY_USER"),
    pwd: _getEnv("SHOPIXY_PASSWORD"),
    roles: [
        {
            role: "readWrite",
            db: _getEnv("SHOPIXY_DB")
        }
    ]
});

print("Application user created");


} catch (e) {

print("Application user already exists");

}


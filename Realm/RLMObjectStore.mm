////////////////////////////////////////////////////////////////////////////
//
// Copyright 2014 Realm Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
////////////////////////////////////////////////////////////////////////////

#import "RLMRealm_Private.hpp"
#import "RLMArray_Private.hpp"
#import "RLMSchema_Private.h"
#import "RLMObjectSchema_Private.hpp"
#import "RLMObject_Private.h"
#import "RLMAccessor.h"
#import "RLMQueryUtil.hpp"
#import "RLMUtil.hpp"

#import <objc/runtime.h>

// initializer
void RLMInitializeObjectStore() {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // register accessor cache
        RLMAccessorCacheInitialize();
    });
}

// get the table used to store object of objectClass
inline tightdb::TableRef RLMTableForObjectClass(RLMRealm *realm,
                                                NSString *className) {
    NSString *tableName = realm.schema.tableNamesForClass[className];
    return realm.group->get_table(tableName.UTF8String);
}


// create a column for a property in a table
void RLMCreateColumn(RLMRealm *realm, tightdb::Table *table, RLMProperty *prop) {
    switch (prop.type) {
            // for objects and arrays, we have to specify target table
        case RLMPropertyTypeObject:
        case RLMPropertyTypeArray: {
            tightdb::TableRef linkTable = RLMTableForObjectClass(realm, prop.objectClassName);
            table->add_column_link(tightdb::DataType(prop.type), prop.name.UTF8String, *linkTable);
            break;
        }
        default: {
            size_t column = table->add_column((tightdb::DataType)prop.type, prop.name.UTF8String);
            if (prop.attributes & RLMPropertyAttributeIndexed) {
                table->set_index(column);
            }
            break;
        }
    }
}

void RLMVerifyTable(tightdb::Table *table, RLMObjectSchema *objectSchema) {
    // FIXME - handle case where columns are reordered in this method by reassigning property column indexes
    // FIXME - this method should calculate all mismatched colums, and missing/extra columns, and include
    //         all of this information in a single exception
    // FIXME - verify property attributes
    
    // for now loop through all columns and ensure they are aligned
    RLMObjectSchema *tableSchema = [RLMObjectSchema schemaForTable:table className:objectSchema.className];
    if (tableSchema.properties.count != objectSchema.properties.count) {
        @throw [NSException exceptionWithName:@"RLMException"
                                       reason:@"Column count does not match interface - migration required"
                                     userInfo:nil];
    }

    for (NSUInteger i = 0; i < objectSchema.properties.count; i++) {
        RLMProperty *tableProp = tableSchema.properties[i];
        RLMProperty *schemaProp = objectSchema.properties[i];
        if (![tableProp.name isEqualToString:schemaProp.name]) {
            @throw [NSException exceptionWithName:@"RLMException"
                                           reason:@"Existing property does not match interface - migration required"
                                         userInfo:@{@"property num": @(i),
                                                    @"existing property name": tableProp.name,
                                                    @"new property name": schemaProp.name}];
        }
        if (tableProp.type != schemaProp.type) {
            @throw [NSException exceptionWithName:@"RLMException"
                                           reason:@"Property types do not match - migration required"
                                         userInfo:@{@"property name": tableProp.name,
                                                    @"existing property type": RLMTypeToString(tableProp.type),
                                                    @"new property type": RLMTypeToString(schemaProp.type)}];
        }
        if (tableProp.type == RLMPropertyTypeObject || tableProp.type == RLMPropertyTypeArray) {
            if (![tableProp.objectClassName isEqualToString:schemaProp.objectClassName]) {
                @throw [NSException exceptionWithName:@"RLMException"
                                               reason:@"Property objectClass does not match - migration required"
                                             userInfo:@{@"property name": tableProp.name,
                                                        @"existign objectClass": tableProp.objectClassName,
                                                        @"new property name": schemaProp.objectClassName}];
            }
        }
    }
}

void RLMVerifyAndCreateTables(RLMRealm *realm) {
    [realm beginWriteTransaction];
    
    // first pass create missing tables and verify existing
    for (RLMObjectSchema *objectSchema in realm.schema.objectSchema) {
        tightdb::TableRef table = RLMTableForObjectClass(realm, objectSchema.className);
        if (table->get_column_count()) {
            RLMVerifyTable(table.get(), objectSchema);
        }
    }
    
    // second pass add columns to empty tables
    for (RLMObjectSchema *objectSchema in realm.schema.objectSchema) {
        tightdb::TableRef table = RLMTableForObjectClass(realm, objectSchema.className);
        if (table->get_column_count() == 0) {
            for (RLMProperty *prop in objectSchema.properties) {
                RLMCreateColumn(realm, table.get(), prop);
            }
        }
    }
    [realm commitWriteTransaction];
}

void RLMAddObjectToRealm(RLMObject *object, RLMRealm *realm) {
    // if already in the right realm then no-op
    if (object.realm == realm) {
        return;
    }
    
    // if realm is not writable throw
    if (!realm.inWriteTransaction) {
        @throw [NSException exceptionWithName:@"RLMException"
                                       reason:@"Can only add an object to a Realm during a write transaction"
                                     userInfo:nil];
    }
    
    // get table and create new row
    NSString *objectClassName = object.RLMObject_schema.className;
    object.realm = realm;
    object.RLMObject_schema = realm.schema[objectClassName];
    
    tightdb::TableRef table = RLMTableForObjectClass(realm, objectClassName);
    size_t rowIndex = table->add_empty_row();
    object->_row = (*table)[rowIndex];

    // change object class to insertion accessor
    RLMObjectSchema *schema = realm.schema[objectClassName];
    Class objectClass = NSClassFromString(objectClassName);
    object_setClass(object, RLMInsertionAccessorClassForObjectClass(objectClass, schema));

    // call our insertion setter to populate all properties in the table
    for (RLMProperty *prop in schema.properties) {
        // InsertionAccessr getter gets object from ivar
        id value = [object valueForKey:prop.name];
        
        // FIXME: Add condition to check for Mixed or Object types because they can support a nil value.
        if (value) {
            // InsertionAccssor setter inserts into table
            [object setValue:value forKey:prop.name];
        }
        else {
            @throw [NSException exceptionWithName:@"RLMException"
                                           reason:[NSString stringWithFormat:@"No value or default value specified for %@ property", prop.name]
                                         userInfo:nil];
        }
    }
    
    // we are in a read transaction so change accessor class to readwrite accessor
    object_setClass(object, RLMAccessorClassForObjectClass(objectClass, schema));
    
    // register object with the realm
    [realm registerAccessor:object];
}

void RLMDeleteObjectFromRealm(RLMObject *object) {
    // if realm is not writable throw
    if (!object.realm.inWriteTransaction) {
        @throw [NSException exceptionWithName:@"RLMException" reason:@"Can only delete objects from a Realm during a write transaction" userInfo:nil];
    }
    // move last row to row we are deleting
    object->_row.get_table()->move_last_over(object->_row.get_index());
    // FIXME - fix all accessors
}

RLMArray *RLMGetObjects(RLMRealm *realm, NSString *objectClassName, NSPredicate *predicate, NSString *order) {
    // get table for this calss
    tightdb::TableRef table = RLMTableForObjectClass(realm, objectClassName);
    
    // create view from table and predicate
    RLMObjectSchema *schema = realm.schema[objectClassName];
    tightdb::Query *query = new tightdb::Query(table->where());
    RLMUpdateQueryWithPredicate(query, predicate, schema);
    
    // create view and sort
    tightdb::TableView view = query->find_all();
    RLMUpdateViewWithOrder(view, schema, order, YES);
    
    // create and populate array
    __autoreleasing RLMArray * array = [RLMArrayTableView arrayWithObjectClassName:objectClassName
                                                                             query:query view:view
                                                                             realm:realm];
    return array;
}

// Create accessor and register with realm
RLMObject *RLMCreateObjectAccessor(RLMRealm *realm, NSString *objectClassName, NSUInteger index) {
    // get object classname to use from the schema
    Class objectClass = [realm.schema objectClassForClassName:objectClassName];
    
    // get acessor fot the object class
    Class accessorClass = RLMAccessorClassForObjectClass(objectClass, realm.schema[objectClassName]);
    RLMObject *accessor = [[accessorClass alloc] initWithRealm:realm
                                                        schema:realm.schema[objectClassName]
                                                 defaultValues:NO];

    tightdb::TableRef table = RLMTableForObjectClass(realm, objectClassName);
    accessor->_row = (*table)[index];
    accessor.RLMAccessor_writable = realm.inWriteTransaction;
    
    [accessor.realm registerAccessor:accessor];
    return accessor;
}



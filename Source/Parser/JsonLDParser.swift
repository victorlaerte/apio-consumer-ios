/**
* Copyright (c) 2000-present Liferay, Inc. All rights reserved.
*
* This library is free software; you can redistribute it and/or modify it under
* the terms of the GNU Lesser General Public License as published by the Free
* Software Foundation; either version 2.1 of the License, or (at your option)
* any later version.
*
* This library is distributed in the hope that it will be useful, but WITHOUT
* ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
* FOR A PARTICULAR PURPOSE. See the GNU Lesser General Public License for more
* details.
*/

import Foundation

/**
* @author Igor Matos
* @author Allan Melo
*/
class JsonLDParser {
	
	typealias OptionalAttributes = [String: Any?]
	typealias Attributes = [String: Any]
	typealias Context = [Any]
	
	static func contextFrom(context: Context?, parentContext: Context?) -> Context {
		if let context = context, let parentContext = parentContext {
			if !hasVocab(jsonObject: context) && hasVocab(jsonObject: parentContext)  {
				var context = context
				
				context.append( ["@vocab": getVocab(context: parentContext) ?? ""])
				
				return context
			}
		}
		
		return context ?? parentContext ?? [] 
	}
	
	static func filterProperties(
		json: OptionalAttributes, properties: [String]) -> OptionalAttributes {
		
		let keys = json.keys.filter { !properties.contains($0) }
		
		let filteredProperties = keys.reduce(OptionalAttributes(), { acc, key in
			var acc = acc
			
			guard let value = json[key] else {
				return acc
			}
			
			acc.updateValue(value, forKey: key)
			
			return acc
		})
		
		return filteredProperties
	}
	
	static func flatten(
		context: Context, foldedAttributes: inout OptionalAttributes, attributes: Attributes)
		-> OptionalAttributes {
		
		let key = attributes.keys.first ?? ""
		let value = attributes.values.first ?? ""
		
		var attributes = foldedAttributes["attributes"] as? OptionalAttributes ?? OptionalAttributes()
		var things = foldedAttributes["things"] as? OptionalAttributes ?? OptionalAttributes()
		
		if let value = value as? OptionalAttributes {
			parseObject(key: key, value: value, context: context, attributes: &attributes, 
						things: &things)
		}
		else if let value = value as? [Attributes] {
			parseObjectArray(key: key, value: value, context: context, attributes: &attributes, 
							 things: &things)
		}
		else if isId(name: key, context: context) {
			let value =  value as? String ?? ""
			let relation = Relation(id: value, thing: nil)
			
			let null: Any? = nil
			things[value] = null
			
			attributes[key] = relation
		}
		else {
			attributes[key] = value
		}
		
		return ["attributes" : attributes, "things" : things]
	}
	
	static func getVocab(context: Context) -> String? {
		return context.first { item in
			if let item = item as? Attributes, item.keys.contains("@vocab") {
				return true
			}
			
			return false
			} as? String
	}
	
	static func hasVocab(jsonObject: Context) -> Bool {
		return getVocab(context: jsonObject) != nil
	}
	
	static func isEmbeddedThingArray(value: Context) -> Bool {
		if let firstPair = value.first as? Attributes {
			return firstPair["@id"] != nil
		}
		
		return false
	}
	
	static func isId(name: String, context: Context?) -> Bool {
		guard let context = context else {
			return false
		}
		
		return context.first { item in
			if let attrs = item as? OptionalAttributes,
				let value = attrs[name] as? OptionalAttributes,
				let type = value["@type"] as? String, type == "@id" {
				
				return true
			}
			
			return false
			} != nil
	}
	
	static func parseAttributes(
		json: OptionalAttributes, context: Context) -> (Attributes, OptionalAttributes) {
		let filteredJson = filterProperties(json: json, properties: ["@id", "@context", "@type"])
		
        let result = filteredJson.keys
            .reduce(
				into: ["attributes": OptionalAttributes(), "things": OptionalAttributes()], { acc, key in
                acc = flatten(context: context, foldedAttributes: &acc, attributes: [key : json[key] as Any] as Attributes)
            })
        
		let attributes = result["attributes"] as? Attributes ?? [:]
		let things = result["things"] as? OptionalAttributes ??  [:]
		
		return (attributes, things)
	}
	
	static func parseObject(
		key: String, value: OptionalAttributes, context: Context, attributes: inout OptionalAttributes, things: inout OptionalAttributes) {
		
		if (value.keys.contains("@id")) {
			let (thing, embbededThings) = parseThing(json: value, parentContext: context)
			
			attributes[key] = Relation(id: thing.id, thing: thing)
			
			things.merge(embbededThings) { first, second  in
				return first
			}
			
			things[thing.id] = thing
		}
		else {
			let (parsedAttributes, parsedEmbbededThings) = parseAttributes(json: value, 
																		   context: context)
			
			attributes[key] = parsedAttributes
			
			things.merge(parsedEmbbededThings) { first, second in
				return first 
			}
		}
	}
	
	static func parseObjectArray(
		key: String, value: Context, context: Context, attributes: inout OptionalAttributes, things: inout OptionalAttributes) {

		if (isEmbeddedThingArray(value: value)) {
			let collection = value.map { parseThing(json: $0 as? OptionalAttributes ?? [:]) }

			var relations = [Relation]()
			
			for (thing, embbededThings) in collection {
				let relation = Relation(id: thing.id, thing: thing)
				
				relations.append(relation)
				
				things.merge(embbededThings) { first, second in
					return second 
				}
				
				things[thing.id] = thing
			}
			
			attributes[key] = relations
		}
		else {
			let collection = 
					value.map { parseAttributes(json: $0 as? OptionalAttributes ?? [:], context: context) }
			
			var attributesList = [OptionalAttributes]()
			
			for (embeddedAttributes, embeddedThings) in collection {
				attributesList.append(embeddedAttributes)
				
				things.merge(embeddedThings) { first, second in
					return second
				}
				
				attributes[key] = attributesList
			}
		}
	}
	
	static func parseOperations(json: OptionalAttributes) -> [String: Operation] {
		let operationsJson = json["operation"] as? [OptionalAttributes] ?? []
		
		let operations = operationsJson.map { operationJson -> Operation in
			let id = operationJson["@id"] as? String ?? ""
			let target = operationJson["target"] as? String ?? ""
			let method = operationJson["method"] as? String ?? ""
			let expects = operationJson["expects"] as? String ?? ""
			let types = operationJson["@type"] as? [String] ?? []
			
			return Operation(id: id, target: target, method: method, expects: expects, types: types)
		}

		return operations.reduce(into: [String: Operation]()) { (acc, operation) in
			acc[operation.id] = operation
		}		
	}
	
	static func parseThing(json: OptionalAttributes, parentContext: Context? = nil) -> (Thing, OptionalAttributes) {
		let id = json["@id"] as? String ?? ""
		let types = parseType(json["@type"] ?? nil)
		let context = 
			contextFrom(context: json["@context"] as? Context ?? [], parentContext: parentContext)
		
		let operations = parseOperations(json: json)
		let (attributes, things) = parseAttributes(json: json, context: context)
		
		let thing = Thing(id: id, types: types, attributes: attributes, operations: operations)
		
		return (thing, things)
	}
	
	static func parseType(_ type: Any?) -> [String] {
		switch type {
		case let type as String:
			return [type]
		case let type as [String]:
			return type
		default:
			return []
		}
	}
}

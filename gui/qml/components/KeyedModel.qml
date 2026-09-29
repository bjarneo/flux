import QtQuick

// A list model that follows an array of objects by key. A Repeater with a
// plain array builds every delegate again when one field of one object
// changes. This model inserts, moves, and removes only the rows that
// changed, so the other delegates stay alive with their state. Each row
// holds only the key. A delegate reads the object from byId:
//
//   KeyedModel { id: rows; values: root.transfers }
//   Repeater {
//     model: rows
//     delegate: Card {
//       required property string key
//       readonly property var modelData: rows.byId[key] || ({})
//     }
//   }
ListModel {
  id: root

  // The array to follow.
  property var values: []
  // The field that identifies an object in values.
  property string keyField: "id"
  // The objects of values by key. A new array gives a new map, so the
  // bindings of the delegates read the new objects. The map has no
  // prototype, so a key from a phone such as "__proto__" or
  // "hasOwnProperty" is an ordinary key.
  property var byId: Object.create(null)
  // A new scope, for example the ID of another device, removes every row
  // first. Then no delegate keeps the state of an object from the earlier
  // scope that has the same key.
  property string scope: ""

  // The keys of the rows, in the order of the rows.
  property var rowKeys: []

  onValuesChanged: sync()
  onScopeChanged: {
    root.clear()
    rowKeys = []
    sync()
  }

  function sync() {
    var list = values || []
    var keys = []
    var map = Object.create(null)
    for (var i = 0; i < list.length; i++) {
      var k = list[i] ? list[i][keyField] : undefined
      // An object with no key, or with the key of an earlier object, gets
      // a key from its position.
      k = k === undefined || k === null || k === "" ? "#" + i : String(k)
      while (k in map) k = k + "#" + i
      keys.push(k)
      map[k] = list[i]
    }

    // Remove the old rows first, while byId still has their objects.
    var rows = rowKeys.slice()
    for (var r = rows.length - 1; r >= 0; r--) {
      if (!(rows[r] in map)) {
        root.remove(r)
        rows.splice(r, 1)
      }
    }
    byId = map

    // Each key is unique, so a key that is not at its position is further
    // down.
    for (var j = 0; j < keys.length; j++) {
      if (rows[j] === keys[j]) continue
      var from = rows.indexOf(keys[j], j + 1)
      if (from >= 0) {
        root.move(from, j, 1)
        rows.splice(from, 1)
      } else {
        root.insert(j, { key: keys[j] })
      }
      rows.splice(j, 0, keys[j])
    }
    rowKeys = rows
  }
}

# class PersonyzeCondition (Personyze iOS SDK reference)

This object represents a matching condition (aka campaign). You get condition objects from call to [PersonyzeTracker.inst.getResult()](../PersonyzeTracker/README.md#personyzetrackerinstgetresult)

### condition.id

```java
var id: Int
```

Readonly field holding the condition ID that distinguishes one condition from another. This is Personyze internal property.

### condition.name

```java
var name: String?
```

Readonly field holding the campaign name - how you called it in the Personyze panel.

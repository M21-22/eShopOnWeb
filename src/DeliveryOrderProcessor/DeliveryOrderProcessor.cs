using System.Net;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Azure.Cosmos;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;
using Microsoft.Extensions.Logging;

namespace OrderItemsReserver;

public class DeliveryOrderProcessor
{
    private readonly ILogger<DeliveryOrderProcessor> _logger;

    public DeliveryOrderProcessor(ILogger<DeliveryOrderProcessor> logger)
    {
        _logger = logger;
    }

    [Function("DeliveryOrderProcessor")]
    public async Task<HttpResponseData> Run(
        [HttpTrigger(AuthorizationLevel.Function, "post")]
        HttpRequestData req)
    {
        var body = await new StreamReader(req.Body).ReadToEndAsync();

        var deliveryOrder = JsonSerializer.Deserialize<DeliveryOrder>(body, new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true
        });

        if (deliveryOrder is null || string.IsNullOrWhiteSpace(deliveryOrder.OrderId))
        {
            var badResponse = req.CreateResponse(HttpStatusCode.BadRequest);
            await badResponse.WriteStringAsync("Invalid delivery order payload.");
            return badResponse;
        }

        var orderId = deliveryOrder.OrderId.Trim();

        var cosmosDocument = new
        {
            id = orderId,
            orderId = orderId,
            shippingAddress = deliveryOrder.ShippingAddress,
            items = deliveryOrder.Items.Select(i => new
            {
                productName = i.ProductName,
                unitPrice = i.UnitPrice,
                units = i.Units
            }).ToList(),
            finalPrice = deliveryOrder.FinalPrice
        };

        var connectionString = Environment.GetEnvironmentVariable("CosmosDbConnection");
        var databaseName = Environment.GetEnvironmentVariable("CosmosDbDatabase") ?? "DeliveryDb";
        var containerName = Environment.GetEnvironmentVariable("CosmosDbContainer") ?? "Orders";

        using var cosmosClient = new CosmosClient(connectionString);

        var database = await cosmosClient.CreateDatabaseIfNotExistsAsync(databaseName);
        var container = await database.Database.CreateContainerIfNotExistsAsync(
            id: containerName,
            partitionKeyPath: "/orderId"
        );

        await container.Container.UpsertItemAsync(
            cosmosDocument,
            new PartitionKey(orderId)
        );

        _logger.LogInformation("Delivery order {OrderId} saved to Cosmos DB.", orderId);

        var response = req.CreateResponse(HttpStatusCode.OK);
        await response.WriteStringAsync($"Delivery order {orderId} saved.");
        return response;
    }
}

public class DeliveryOrder
{
    [JsonPropertyName("id")]
    public string Id { get; set; } = "";

    [JsonPropertyName("orderId")]
    public string OrderId { get; set; } = "";

    [JsonPropertyName("shippingAddress")]
    public string ShippingAddress { get; set; } = "";

    [JsonPropertyName("items")]
    public List<DeliveryOrderItem> Items { get; set; } = new();

    [JsonPropertyName("finalPrice")]
    public decimal FinalPrice { get; set; }
}

public class DeliveryOrderItem
{
    [JsonPropertyName("productName")]
    public string ProductName { get; set; } = "";

    [JsonPropertyName("unitPrice")]
    public decimal UnitPrice { get; set; }

    [JsonPropertyName("units")]
    public int Units { get; set; }
}
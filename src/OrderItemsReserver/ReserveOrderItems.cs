using System.Text.Json;
using Azure.Storage.Blobs;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;

namespace OrderItemsReserver;

public class ReserveOrderItems
{
    private readonly ILogger<ReserveOrderItems> _logger;

    public ReserveOrderItems(ILogger<ReserveOrderItems> logger)
    {
        _logger = logger;
    }

    [Function("ReserveOrderItems")]
    public async Task Run(
        [ServiceBusTrigger("order-items-reservation", Connection = "ServiceBusConnection")]
        string message)
    {
        _logger.LogInformation("ReserveOrderItems received message from Service Bus.");

        var storageConnectionString =
            Environment.GetEnvironmentVariable("BlobStorageConnectionString");

        if (string.IsNullOrWhiteSpace(storageConnectionString))
        {
            throw new InvalidOperationException("BlobStorageConnectionString is missing.");
        }

        var containerName =
            Environment.GetEnvironmentVariable("BlobContainerName")
            ?? "order-requests";

        var blobServiceClient = new BlobServiceClient(storageConnectionString);
        var containerClient = blobServiceClient.GetBlobContainerClient(containerName);

        await containerClient.CreateIfNotExistsAsync();

        var orderRequest = JsonSerializer.Deserialize<OrderReservationRequest>(
            message,
            new JsonSerializerOptions
            {
                PropertyNameCaseInsensitive = true
            });

        if (orderRequest == null)
        {
            throw new InvalidOperationException("Invalid order reservation message.");
        }

        var fileName = $"order-{orderRequest.OrderId}-{DateTime.UtcNow:yyyyMMddHHmmss}.json";
        var blobClient = containerClient.GetBlobClient(fileName);

        await blobClient.UploadAsync(BinaryData.FromString(message), overwrite: true);

        _logger.LogInformation("Order request uploaded to Blob Storage: {FileName}", fileName);
    }
}

public class OrderReservationRequest
{
    public int OrderId { get; set; }
    public List<OrderReservationItem> Items { get; set; } = new();
}

public class OrderReservationItem
{
    public int ItemId { get; set; }
    public int Quantity { get; set; }
}
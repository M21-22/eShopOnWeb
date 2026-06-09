using System.Net;
using Azure.Storage.Blobs;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;
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
    public async Task<HttpResponseData> Run(
        [HttpTrigger(AuthorizationLevel.Function, "post")]
        HttpRequestData req)
    {
        var body = await new StreamReader(req.Body).ReadToEndAsync();

        var connectionString =
            Environment.GetEnvironmentVariable("BlobStorageConnectionString");

        var containerName =
            Environment.GetEnvironmentVariable("BlobContainerName") ?? "order-requests";

        var containerClient =
            new BlobContainerClient(connectionString, containerName);

        await containerClient.CreateIfNotExistsAsync();

        var blobName =
            $"order-{DateTime.UtcNow:yyyyMMddHHmmss}-{Guid.NewGuid():N}.json";

        await containerClient.UploadBlobAsync(blobName, BinaryData.FromString(body));

        var response = req.CreateResponse(HttpStatusCode.OK);
        await response.WriteStringAsync(blobName);

        return response;
    }
}
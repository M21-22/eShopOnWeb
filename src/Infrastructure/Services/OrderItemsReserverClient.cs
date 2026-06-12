using System;
using System.Linq;
using System.Net.Http;
using System.Net.Http.Json;
using System.Threading.Tasks;
using Microsoft.eShopWeb.ApplicationCore.Entities.OrderAggregate;
using Microsoft.eShopWeb.ApplicationCore.Interfaces;
using Microsoft.Extensions.Configuration;
using Azure.Messaging.ServiceBus;
using System.Text.Json;

namespace Microsoft.eShopWeb.Infrastructure.Services;

public class OrderItemsReserverClient : IOrderItemsReserverClient
{
    private readonly HttpClient _httpClient;
    private readonly string? _deliveryOrderProcessorUrl;
    private readonly string? _serviceBusConnectionString;
    private readonly string _queueName = "order-items-reservation";

    public OrderItemsReserverClient(HttpClient httpClient, IConfiguration configuration)
    {
        _httpClient = httpClient;
        _deliveryOrderProcessorUrl = configuration["DeliveryOrderProcessorUrl"];
        _serviceBusConnectionString = configuration["ServiceBusConnection"];
    }

    public async Task ReserveAsync(Order order)
    {
        var reservePayload = new
        {
            orderId = order.Id,
            items = order.OrderItems.Select(i => new
            {
                itemId = i.ItemOrdered.CatalogItemId,
                quantity = i.Units
            })
        };

        var deliveryPayload = new
        {
            orderId = order.Id.ToString(),

            shippingAddress =
                $"{order.ShipToAddress.Street}, " +
                $"{order.ShipToAddress.City}, " +
                $"{order.ShipToAddress.State}, " +
                $"{order.ShipToAddress.Country}, " +
                $"{order.ShipToAddress.ZipCode}",

            items = order.OrderItems.Select(i => new
            {
                productName = i.ItemOrdered.ProductName,
                unitPrice = i.UnitPrice,
                units = i.Units
            }),

            finalPrice = order.Total()
        };

        if (!string.IsNullOrWhiteSpace(_serviceBusConnectionString))
        {
            await using var client = new ServiceBusClient(_serviceBusConnectionString);
            ServiceBusSender sender = client.CreateSender(_queueName);

            var messageJson = JsonSerializer.Serialize(reservePayload);
            await sender.SendMessageAsync(new ServiceBusMessage(messageJson));
        }

        if (!string.IsNullOrWhiteSpace(_deliveryOrderProcessorUrl))
        {
            var deliveryResponse = await _httpClient.PostAsJsonAsync(_deliveryOrderProcessorUrl, deliveryPayload);
            deliveryResponse.EnsureSuccessStatusCode();
        }
    }
}
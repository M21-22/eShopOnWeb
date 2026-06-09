using System.Net.Http.Json;
using Microsoft.eShopWeb.ApplicationCore.Entities.OrderAggregate;
using Microsoft.eShopWeb.ApplicationCore.Interfaces;

namespace Microsoft.eShopWeb.Infrastructure.Services;

public class OrderItemsReserverClient : IOrderItemsReserverClient
{
    private readonly HttpClient _httpClient;

    public OrderItemsReserverClient(HttpClient httpClient)
    {
        _httpClient = httpClient;
    }

    public async Task ReserveAsync(Order order)
    {
        var payload = new
        {
            orderId = order.Id,
            items = order.OrderItems.Select(i => new
            {
                itemId = i.ItemOrdered.CatalogItemId,
                quantity = i.Units
            })
        };

        await _httpClient.PostAsJsonAsync("", payload);
    }
}